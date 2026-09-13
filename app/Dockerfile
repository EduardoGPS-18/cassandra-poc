# Imagem do gerador de carga. Python 3.11 (combinação estável com o
# cassandra-driver; evita a remoção do asyncore que ocorre no 3.12).
FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY loadgen.py .

# Logs sem buffer => aparecem em tempo real no `kubectl logs -f`.
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python", "loadgen.py"]
