FROM --platform=$TARGETPLATFORM nginx:1.24-alpine

# Copy web files
COPY . /usr/share/nginx/html/

# Copy nginx configuration
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Create favicon if it doesn't exist
RUN touch /usr/share/nginx/html/favicon.ico

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
