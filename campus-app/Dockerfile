FROM mirror.gcr.io/library/python:3.13-slim
WORKDIR /app
COPY app.py /app/app.py
ARG APP_VERSION=dev
RUN useradd --uid 10001 --create-home appuser
USER 10001
ENV PORT=8080 \
    APP_VERSION=${APP_VERSION} \
    READY=true \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
EXPOSE 8080
ENTRYPOINT ["python", "/app/app.py"]
