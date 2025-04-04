#!/bin/bash

# Create necessary directories
mkdir -p ./victoria-data
mkdir -p ./grafana-data
mkdir -p ./grafana/provisioning/datasources

# Write Docker Compose configuration
cat > docker-compose.yml << 'EOF'
version: '3.8'
services:
  victoriametrics:
    image: victoriametrics/victoria-metrics:latest
    container_name: victoria-metrics
    ports:
      - "8428:8428"  # VictoriaMetrics API
    volumes:
      - ./victoria-data:/victoria-metrics-data
    command:
      - '--retentionPeriod=30d'
    restart: always
    networks:
      - monitoring-network

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"  # Grafana UI
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - ./grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
    restart: always
    networks:
      - monitoring-network
    depends_on:
      - victoriametrics

networks:
  monitoring-network:
    driver: bridge
EOF

# Create Grafana datasource configuration
mkdir -p ./grafana/provisioning/datasources
cat > ./grafana/provisioning/datasources/datasource.yaml << 'EOF'
apiVersion: 1

datasources:
  - name: VictoriaMetrics
    type: prometheus
    access: proxy
    url: http://victoriametrics:8428
    isDefault: true
    editable: true
EOF

# Create OpenTelemetry Collector configuration
cat > otelcol-config.yaml << 'EOF'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
      http:
        endpoint: "0.0.0.0:4318"
  
  hostmetrics:
    collection_interval: 10s
    scrapers:
      cpu:
      disk:
      load:
      filesystem:
      memory:
      network:
      paging:
      process:

processors:
  batch:
    timeout: 10s
    send_batch_size: 1024
  
  resource:
    attributes:
      - key: service.name
        value: "system-monitoring"
        action: upsert

exporters:
  prometheusremotewrite:
    endpoint: "http://localhost:8428/api/v1/write"
    tls:
      insecure: true
  
  debug:
    verbosity: detailed

service:
  pipelines:
    metrics:
      receivers: [otlp, hostmetrics]
      processors: [batch, resource]
      exporters: [prometheusremotewrite, debug]
    
    traces:
      receivers: [otlp]
      processors: [batch, resource]
      exporters: [debug]
    
    logs:
      receivers: [otlp]
      processors: [batch, resource]
      exporters: [debug]

  telemetry:
    logs:
      level: debug
EOF

# Copy OTEL config to system location
echo "Updating OpenTelemetry Collector configuration..."
sudo cp otelcol-config.yaml /etc/otelcol/config.yaml

# Stop and restart OpenTelemetry Collector service
echo "Restarting OpenTelemetry Collector service..."
sudo systemctl restart otelcol

# Start the Docker services
echo "Starting Victoria Metrics and Grafana..."
docker-compose down
docker-compose up -d

# Wait for services to start
echo "Waiting for services to initialize (15 seconds)..."
sleep 15

# Check OTEL collector status
echo "Checking OpenTelemetry Collector status:"
sudo systemctl status otelcol --no-pager

# Check if metrics are flowing
echo "Checking if metrics are flowing to VictoriaMetrics..."
METRIC_COUNT=$(curl -s http://localhost:8428/api/v1/series -d 'match[]={__name__!=""}' | grep -o '"__name__":"[^"]*"' | wc -l)

if [ $METRIC_COUNT -gt 0 ]; then
    echo "SUCCESS: $METRIC_COUNT metrics found in VictoriaMetrics!"
    echo "You can access Grafana at http://localhost:3000 (admin/admin)"
    echo "Available metrics in VictoriaMetrics:"
    curl -s http://localhost:8428/api/v1/label/__name__/values | head -20
else
    echo "ERROR: No metrics found in VictoriaMetrics"
    echo "Checking OTEL collector logs:"
    sudo journalctl -u otelcol -n 50 --no-pager
fi
