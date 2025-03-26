proc server_name_and_version {} {
    set server_name [s server_name]
    if {$server_name eq {}} {
        set server_name redis
    }
    set server_version [s "${server_name}_version"]
    return "$server_name $server_version"
}

tags {external:skip needs:other-server cluster} {
    start_cluster 1 0 {tags {external:skip cluster}} {
        set first_shard_host [srv 0 host]
        set first_shard_port [srv 0 port]
        set first_shard_name_and_version [server_name_and_version]

        start_server {tags {"external:skip"} overrides {cluster-enabled {yes}} start-other-server 1} {
            test "Join a node to the cluster and make sure it gets the same secret from $first_shard_name_and_version" {
                r cluster meet $first_shard_host $first_shard_port
                wait_for_cluster_state "ok"

                r cluster REPLICATE [R 1 CLUSTER MYID]
                wait_for_condition 50 100 {
                    [r cluster myshardid] eq [R 1 cluster myshardid]
                } else {
                    puts [r cluster myshardid]
                    puts [r -1 cluster myshardid]
                    fail "Secrets not match"
                }
            }
        }
    }

    start_cluster 1 0 {tags {external:skip cluster} start-other-server 1} {
        set first_shard_host [srv 0 host]
        set first_shard_port [srv 0 port]

        start_server {tags {"external:skip"} overrides {cluster-enabled {yes}}} {
            set first_shard_name_and_version [server_name_and_version]
            test "Join a node to the cluster and make sure it gets the same secret from $first_shard_name_and_version" {
                r cluster meet $first_shard_host $first_shard_port
                wait_for_cluster_state "ok"

                r cluster REPLICATE [R 1 CLUSTER MYID]
                wait_for_condition 50 100 {
                    [r cluster myshardid] eq [R 1 cluster myshardid]
                } else {
                    puts [r cluster myshardid]
                    puts [r -1 cluster myshardid]
                    fail "Secrets not match"
                }
            }
        }
    }
}