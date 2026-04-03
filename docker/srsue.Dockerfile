# =============================================================================
# srsUE — ZMQ-enabled UE simulator from srsRAN_4G
# Built from source with ZMQ RF support (no hardware needed)
# =============================================================================
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake ninja-build \
    libfftw3-dev libmbedtls-dev \
    libboost-program-options-dev libboost-system-dev \
    libconfig++-dev libsctp-dev libzmq3-dev \
  && rm -rf /var/lib/apt/lists/*

COPY . /src
WORKDIR /src/build

RUN cmake -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_SRSENB=OFF \
    -DENABLE_SRSEPC=OFF \
    .. && \
    ninja srsue srsran_rf_zmq

# --- Runtime stage ---
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    libfftw3-single3 libmbedtls14 libmbedcrypto7 libmbedx509-1 \
    libboost-program-options1.74.0 \
    libconfig++9v5 libsctp1 libzmq5 \
    iproute2 iputils-ping net-tools \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/build/srsue/src/srsue /usr/local/bin/srsue
COPY --from=builder /src/build/lib/src/phy/rf/libsrsran_rf*.so* /usr/local/lib/
RUN ldconfig

ENTRYPOINT ["srsue"]
