# Prepare a verified official PocketBase linux_amd64 binary at ./pocketbase first.
# The build requires a trusted pinned Alpine image digest supplied via ALPINE_IMAGE.
ARG ALPINE_IMAGE
FROM ${ALPINE_IMAGE}

RUN apk add --no-cache ca-certificates tzdata &&     addgroup -g 10001 pocketbase && adduser -D -H -u 10001 -G pocketbase pocketbase &&     mkdir -p /pb_data && chown -R 10001:10001 /pb_data

COPY --chmod=0555 pocketbase /usr/local/bin/pocketbase
USER 10001:10001
WORKDIR /
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/pocketbase","serve","--http=0.0.0.0:8090","--dir=/pb_data"]
