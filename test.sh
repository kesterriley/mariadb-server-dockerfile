#!/bin/bash
set -e
IMAGE=${1?"Usage: $0 IMAGE_NAME"}

if [[ $IMAGE != "--cleanup" ]]; then
    docker network create cm-galera-test

    docker run -d --name cm-galera-test-seed --network cm-galera-test --network-alias seed \
      -e XTRABACKUP_PASSWORD=foobar \
      -e SKIP_TZINFO=1 \
      $IMAGE seed --log-bin=ON

    sleep 5
    docker logs cm-galera-test-seed
    docker run --name cm-galera-test-node --network cm-galera-test \
      -e XTRABACKUP_PASSWORD=foobar \
      -e SKIP_TZINFO=1 \
      -e GCOMM_MINIMUM=1 \
      $IMAGE node seed --log-bin=ON
fi
if [[ -z $SKIP_CLEANUP ]]; then
    echo "Cleaning up..."
    set +e
    docker stop cm-galera-test-seed
    docker rm -v cm-galera-test-seed
    docker stop cm-galera-test-node
    docker rm -v cm-galera-test-node
    docker network rm cm-galera-test
fi
