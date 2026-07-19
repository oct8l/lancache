FROM nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10

RUN apk add --no-cache openssl curl \
    && openssl req -x509 -nodes -newkey rsa:2048 \
         -keyout /etc/nginx/tls.key -out /etc/nginx/tls.crt \
         -days 3650 -subj "/CN=sniproxy-test.internal"

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY html /usr/share/nginx/html

EXPOSE 443
