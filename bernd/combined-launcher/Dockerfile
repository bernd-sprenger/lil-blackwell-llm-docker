# Combined-entrypoint layer over a cb2-class image: bakes the LIL-pattern
# launcher (stock-LMCache MP server as an in-container child + `vllm serve`)
# so deployments stop shipping supervisor scripts through compose. Thin COPY
# layer — every component is inherited unchanged from the base image.
#
# Build with bernd/build_combined.sh (records the recipe commit as a label).
ARG BASE=ghcr.io/bernd-sprenger/lil-vllm:kk-20261120-cb2
FROM ${BASE}
COPY lil-mp-launcher /usr/local/bin/lil-mp-launcher
RUN chmod 0755 /usr/local/bin/lil-mp-launcher
ENTRYPOINT ["/usr/local/bin/lil-mp-launcher"]
