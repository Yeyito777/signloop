FROM python:3.12-slim
WORKDIR /app
# Deliberately copy only backend source, never the repository/.env or iOS assets.
COPY backend/ ./backend/
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 10001
EXPOSE 8080
CMD ["python", "-m", "backend.server", "--host", "0.0.0.0", "--port", "8080"]
