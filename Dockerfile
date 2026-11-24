FROM node:22-alpine

WORKDIR /app

COPY apps/api/package.json ./apps/api/package.json
RUN cd apps/api && npm install --omit=dev --no-audit --no-fund || true

COPY apps/api ./apps/api
COPY web ./web
COPY harmony-app/entry/src/main/resources/rawfile ./data/rawfile

ENV APP_ENV=huaweicloud \
    PORT=3000 \
    HERITAGE_DATA_FILE=data/rawfile/heritages.json \
    HERITAGE_IMAGE_DIR=data/rawfile/images

EXPOSE 3000
CMD ["node", "apps/api/server.js"]
