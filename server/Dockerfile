FROM node:18-slim

WORKDIR /app

COPY package*.json ./
RUN npm ci --production

COPY index.js ./

EXPOSE 8080

CMD ["node", "index.js"]