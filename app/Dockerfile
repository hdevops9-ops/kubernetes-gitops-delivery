FROM python:3.15-alpine@sha256:a0f2e268f2ce8f3709611a90054ec6a8ae31f6251f5896b8648b9bb99835e30a
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apk upgrade --no-cache
COPY server.py /app/server.py
USER 10001:10001
EXPOSE 8080
CMD ["python", "/app/server.py"]
