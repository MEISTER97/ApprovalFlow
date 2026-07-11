# Stage 1: Build the Flutter Web Application from scratch
FROM ubuntu:22.04 AS build

# Install dependencies needed to download and run Flutter
RUN apt-get update && apt-get install -y curl git unzip xz-utils

# Clone the official Flutter repository directly to the stable branch
RUN git clone https://github.com/flutter/flutter.git -b stable /flutter

# Add Flutter to the system path
ENV PATH="/flutter/bin:${PATH}"

# Set the working directory
WORKDIR /app

# Copy the dependency files first to leverage Docker caching
COPY pubspec.yaml pubspec.lock ./

# Download Flutter packages
RUN flutter pub get

# Copy the rest of the application code
COPY . .

# Build the app for the web
RUN flutter build web

# Stage 2: Serve the compiled app using Nginx
FROM nginx:alpine

# Copy the compiled web assets from the build stage to Nginx
COPY --from=build /app/build/web /usr/share/nginx/html

# Expose port 80 for the Nginx server
EXPOSE 80

# Start Nginx
CMD ["nginx", "-g", "daemon off;"]