FROM alpine:3.22
RUN apk add --no-cache iproute2 python3
RUN mkdir -p /srv/www \
    && printf 'Hello from the lab server\n' > /srv/www/index.html
EXPOSE 8080
CMD ["python3", "-m", "http.server", "8080", \
     "--bind", "0.0.0.0", "--directory", "/srv/www"]
