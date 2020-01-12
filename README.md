# MariaDb Galera Cluster

This Docker container is based on the official Docker `mariadb:10.1` image and is designed to be
compatible with auto-scheduling systems, specifically Docker Swarm Mode (1.12+) and Kontena.
However, it could also work with manual scheduling (`docker run`) by specifying the correct
environment variables or possibly other scheduling systems that use similar conventions.

## How It Works

This is not a simple config update, much effort has gone into making this container automate the initialization
and *recovery* of a cluster. The entrypoint script orchestrates full recovery on simultaneous reset by having
nodes communicate with each other *before* starting the mysqld process to ensure that the cluster is recovered correctly.
It does this by examining Galera's state files, recovering the GTID position on all nodes and then communicating this
between nodes to find the most up-to-date one to form a new cluster if needed. It also provides multiple healthcheck
endpoints for varying degress of healthiness to aid with integration of load balancers and scheduling systems.

### Examples

#### [Kubernetes](https://github.com/colinmollenhour/mariadb-galera-swarm/tree/master/examples/kubernetes)

#### Docker 1.12 Swarm Mode (cli)

```
 $ docker network create --driver overlay galera_network
 $ docker service create --replicas 1 -e XTRABACKUP_PASSWORD=<pass> --network galera_network --name galera-seed \
     colinmollenhour/mariadb-galera-swarm seed
 $ docker service create --replicas 2 -e XTRABACKUP_PASSWORD=<pass> --network galera_network --name galera \
     colinmollenhour/mariadb-galera-swarm node tasks.galera-seed,tasks.galera
 $ docker service rm galera-seed
 $ docker service scale galera=3
```

#### [Docker 1.13 Swarm Mode (stack)](https://github.com/colinmollenhour/mariadb-galera-swarm/blob/master/examples/swarm)

#### [Kontena](https://github.com/colinmollenhour/mariadb-galera-swarm/blob/master/examples/kontena)

Please submit more examples for Kubernetes, Mesos, etc. and also improvements for existing examples!

## Commands

The entrypoint takes as a command one of the following startup "modes":

### seed

Used only to initialize a new cluster and after initialization and other nodes are joined
the "seed" container should be stopped and replaced with a "node" container using the same volume.

### node

Join an existing cluster. Takes as a second argument a comma-separated list of IPs or
hostnames to resolve which are used to build the `--wsrep_cluster_address` option for joining a cluster.

A "node" can actually also be used to bootstrap a cluster as the "seed" does described above by placing a flag
file in the data volume before boot name `/var/lib/mysql/new-cluster`.

### no-galera

Start server with Galera disabled. Useful for maintenance tasks like performing `mysql_upgrade`
and resetting root credentials.

#### Reset root password

For example, to reset the root user password, with the Galera container stopped you can run a new temporary
container like so:

```
shell1 $ docker run --rm -v {volume-name}:/var/lib/mysql --name no-galera-temp {image} no-galera --skip-grant-tables
shell2 $ docker exec -it no-galera-temp mysql -u root mysql
MariaDB> update user set password=password("YOUR_NEW_PASSWORD") where user='root' and host='127.0.0.1';
MariaDB> flush privileges;
MariaDB> quit
shell2 $ exit
shell1 $ <CTRL+C>
```

And now start your Galera container back up with the new root password.

### sleep

Start the container but not the server. Runs "sleep infinity". Useful just to get volumes
initialized or if you want to `docker exec` without the server running.

By using DNS resolution to discover other nodes they don't have to be specified explicitly. This should work
with any system with DNS-based service discovery such as Kontena, Docker Swarm Mode, Consul, etc.

## Environment Variables

 - `XTRABACKUP_PASSWORD` (required unless `XTRABACKUP_PASSWORD_FILE` is provided)
 - `SYSTEM_PASSWORD` (required or set to a hash of `XTRABACKUP_PASSWORD` if provided.)
 - `CLUSTER_NAME` (optional)
 - `NODE_ADDRESS` (optional - defaults to ethwe, then eth0)
 - `LISTEN_WHEN_HEALTHY` (optional) - Specify a port number to open a healthcheck socket on once the cluster
   has reached a healthy state. Useful with Kontena's `wait_for_port` feature.
 - `HEALTHY_WHILE_BOOTING` (optional) - If '1' then the HEALTHCHECK script will report healthy
   during the boot phase (waiting for DNS to resolve and recovering wsrep position).
 - `SKIP_TZINFO` (optional) - Specify any value to skip loading of timezone table data when initing a new directory.
 - `DEFAULT_TIME_ZONE` (optional - defaults to the `TZ` envvar or to '+00:00' if undefined) - Specify the database's time zone, either in numeric format (+01:00) or in verbal format (CET, Europe/Bratislava, etc.). The latter one is possible only if you haven't specified `SKIP_TZINFO`. More information about why you would need this is [here](https://mariadb.com/kb/en/library/time-zones/).
 - `SST_METHOD` (optional - defaults to 'mariabackup' for 10.2+ and 'xtrabackup-v2' for 10.1)  May also be set to 'rsync' or 'mysqldump'.  Other methods requiring further configuration or installed dependencies are not available in this image.
 - `SKIP_UPGRADES` (optional - prevent running `run-upgrades.sh` script)

Additional variables for "seed":

 - `MYSQL_ROOT_PASSWORD` (optional) - See also `/var/lib/mysql/new-cluster` flag file.
 - `MYSQL_ROOT_HOST` (optional) - Defaults to '127.0.0.1' if not specified. Specify '%' to allow root login from any host.
 - `MYSQL_ROOT_SOCKET_AUTH` (optional) - Enabled by default, specify `0` to disable. If enabled `'root'@'localhost'` is created on bootstrap such that
    root can login via the unix socket without a password! This allows `docker exec` commands to work without a password while still requiring a password for
    login over the network.
 - `MYSQL_DATABASE` (optional)
 - `MYSQL_USER` (optional)
 - `MYSQL_PASSWORD` (optional)

Additional variables for "node":

 - `GCOMM_MINIMUM` (optional - defaults to 2)

### Providing secrets through files

It's also possible to configure the sensitive variables using files, a method used by [Docker Swarm](https://docs.docker.com/engine/swarm/secrets/),
Rancher and perhaps others. The paths to the secret files defaults to `/run/secrets/{lower_case_variable_name}`
but can be specified explicitly as well using the following environment variables:

 - `XTRABACKUP_PASSWORD_FILE`
 - `SYSTEM_PASSWORD_FILE`
 - `MYSQL_ROOT_PASSWORD_FILE`
 - `MYSQL_ROOT_HOST_FILE`
 - `MYSQL_PASSWORD_FILE`
 - `MYSQL_DATABASE_FILE`

## Flag Files

In order to accomodate controlling the bootstrapping phase without having to change the CMD which is sometimes
hard to do with automated schedulers you can touch the following files to change the bootstrapping behavior
before starting the container. All files are expected to be in the /var/lib/mysql directory which you should be
mounting as a container volume.

 - `/var/lib/mysql/new-cluster` - Cause a 'node' container to behave as a 'seed' container on it's first run. This
   may also be used for recovery in case a Primary Component cannot be formed or for bootstrapping a fresh cluster
   in place of using the 'seed' container. If the file has any contents they will be used as the `MYSQL_ROOT_PASSWORD`.
 - `/var/lib/mysql/hold-start` - Cause a 'node' container to wait until this file is deleted before trying to boot.
   This could be used in the absence of a scheduler with an easy fine-grained scheduling control.
 - `/var/lib/mysql/force-cluster-bootstrapping` - Force the creation of MySQL users again ('seed' or 'node' command).
 - `/var/lib/mysql/skip-cluster-bootstrapping` - Prevent the creation of MySQL users. This file will be created and
   **should not** be deleted under normal circumstances.
 - `/var/lib/mysql/skip-upgrades` - Prevent running the `run-upgrades.sh` script.

## Health Checks

By default there are two HTTP-based healthcheck servers running in the background.

 - Port 8080 only reports healthy when ready to serve clients. (synced)
 - Port 8081 reports healthy as long as the server is synced or donor/desynced state. This one is used to help
  other nodes determine cluster state before launching the server and also by the Dockerfile HEALTHCHECK command.

The default `HEALTHCHECK` command also returns healthy status if `/var/lib/mysql/sst_in_progress` is present to avoid
a node being killed during an SST. Otherwise it uses the second health check (port 8081) to return healthy only if it
is 'synced' to prevent the node from being killed if it is a donor for a long period of time. How you want the
healthcheck command to behave will vary on your uses for the healthcheck so you may need to override it depending on
the behavior you desire. Regardless, both healthcheck servers will be started and will use negligible resources unless
they are actually being pinged.

Additionally, if a `LISTEN_WHEN_HEALTHY` port number is specified then the container will start a loop checking it's
own port 8080 health check described above until it reports healthy at which point it will open a new socket on this
port which just forwards to port 8080. This can be used with Kontena's `wait_for_port` feature to accomodate the
rolling update mechanism.

## Upgrading

In general, since MariaDb is not a particularly stable server, often introducing regressions or backwards-compatibility
breaks with minor version numbers it is always advised to use specific tags in production and test upgrades on a staging
environment first. Also it is advised to read the commit log to see what changes have been made. No warranty is provided,
use at your own risk!

### Upgrading from 10.1 to 10.2

Before upgrading you need to grant the `PROCESS` privilege to the xtrabackup user:

    mysql> GRANT PROCESS ON *.* TO 'xtrabackup'@'localhost';

# More Info

 - Tries to handle as many recovery scenarios as possible including full cluster ungraceful shutdown by
   using --wsrep-recovery and inter-node communication to discover the optimal node for bootstrapping
   a new cluster when the old one cannot be recovered.
 - If you need to perform manual recovery of a previously healthy cluster you can use "node" mode
   but touch a file at `/var/lib/mysql/new-cluster` to force a node to bootstrap a new cluster
   and bypass the automatic recovery steps.
 - XtraBackup is used for state transfer and MariaDb now supports `pc.recovery` so the primary component should
   automatically be recovered in the case of all nodes being gracefully shutdown. It is important tha all nodes are
   started together so that they can communicate status with each-other.
 - A go server runs within the cluster exposing an http service for intelligent health checking.
    - Port 8080 is used by the Docker 1.12 HEALTHCHECK feature and also can be used by any other health checking
      node in the network such as HAProxy or Consul to determine readable/writeable nodes.
    - Port 8081 is used to detemine cluster status
 - If your container network uses something other than `ethwe*` or `eth0` then you need to specify `NODE_ADDRESS`
   as either the name of the interface to listen on or a grep pattern to match one of the container's IP addresses.
   E.g.: `NODE_ADDRESS='^10.0.1.*'`
 - When using DNS for node address discovery the container entrypoint script will wait indefinitely for
   `GCOMM_MINIMUM` IP addresses to resolve before trying to start `mysqld` in case some containers are starting
   slower than others to increase the chance of a healthy recovery. Scenarios where not enough IPs would resolve
   might include:
    - Some nodes may finish pulling container images from remote repositories sooner than others
    - Schedulers may not be launching nodes quickly enough
    - Service discovery systems may be slow to propagate updates via DNS
 - If the file `/usr/local/lib/startup.sh` exists it will be sourced in the start.sh script.
 - If you need to promote a running node to be a new "Primary Component" you can run the following command to do so:
       $ docker exec -i <container> mysql -p /primary-component.sql
 - You can monitor cluster state changes more clearly by setting `wsrep_notify_cmd` to `/usr/local/bin/notify.sh`
   which will output the updates to the Docker logs/console.

# Credit

 - Forked from ["jakolehm/docker-galera-mariadb-10.0"](https://github.com/jakolehm/docker-galera-mariadb-10.0)
   - Forked from ["sttts/docker-galera-mariadb-10.0"](https://github.com/sttts/docker-galera-mariadb-10.0)
 - galera-healthcheck go binary from ["sttts/galera-healthcheck"](https://github.com/sttts/galera-healthcheck)
