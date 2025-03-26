proc server_name_and_version {} {
    set server_name [s server_name]
    if {$server_name eq {}} {
        set server_name redis
    }
    set server_version [s "${server_name}_version"]
    return "$server_name $server_version"
}

# make sure the test infra won't use SELECT
set old_singledb $::singledb
set ::singledb 1

start_server {tags {"external:skip"} overrides {cluster-enabled {yes}} start-other-server 1} {
    start_server {tags {"external:skip"} overrides {cluster-enabled {yes}}} {
        test "set up cluster" {
            r CLUSTER MEET [srv -1 host] [srv -1 port]
            wait_for_cluster_propagation
            # wait_for_cluster_state "ok"

            # Link establishment requires few PING-PONG between two nodes
            wait_for_condition 50 100 {
                [string match {*handshake*} [r CLUSTER NODES]] eq 0 &&
                [string match {*handshake*} [r -1 CLUSTER NODES]] eq 0
            } else {
                puts [r CLUSTER NODES]
                puts [r -1 CLUSTER NODES]
                fail "Cluster meet stuck in handshake state"
            }
        }

        test "" {
            r CLUSTER REPLICATE [r -1 CLUSTER MYID]
            wait_for_cluster_propagation
            # wait_for_cluster_state "ok"
            wait_for_condition 50 100 {
                [r cluster myshardid] eq [r -1 cluster myshardid]
            } else {
                puts [r cluster myshardid]
                puts [r -1 cluster myshardid]
                fail "Secrets not match"
            }
        }

    }
}

start_server {tags {"external:skip"} overrides {cluster-enabled {yes}}} {
    start_server {tags {"external:skip"} overrides {cluster-enabled {yes}} start-other-server 1} {
        test "set up cluster" {
            r CLUSTER MEET [srv -1 host] [srv -1 port]
            wait_for_cluster_propagation
            # wait_for_cluster_state "ok"

            # Link establishment requires few PING-PONG between two nodes
            wait_for_condition 50 100 {
                [string match {*handshake*} [r CLUSTER NODES]] eq 0 &&
                [string match {*handshake*} [r -1 CLUSTER NODES]] eq 0
            } else {
                puts [r CLUSTER NODES]
                puts [r -1 CLUSTER NODES]
                fail "Cluster meet stuck in handshake state"
            }
        }

        test "" {
            r CLUSTER REPLICATE [r -1 CLUSTER MYID]
            wait_for_condition 50 100 {
                [r cluster myshardid] eq [r -1 cluster myshardid]
            } else {
                puts [r cluster myshardid]
                puts [r -1 cluster myshardid]
                fail "Secrets not match"
            }
        }
    }
}

set ::singledb $old_singledb