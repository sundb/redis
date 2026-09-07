# Test io_uring integration when compiled with USE_IO_URING=yes

proc io_uring_enabled {} {
    set info [r info server]
    if {[string match "*io_uring_enabled:1*" $info]} {
        return 1
    }
    return 0
}

# Basic io_uring test: verify server starts and serves requests
tags {"io_uring"} {
    start_server {} {
        test "io_uring - server info reports io_uring status" {
            set info [r info server]
            # If compiled with io_uring, the fields should be present
            if {[string match "*io_uring_enabled*" $info]} {
                assert_match "*io_uring_enabled:*" $info
                assert_match "*io_uring_batch_writes:*" $info
                assert_match "*io_uring_batch_reads:*" $info
            }
        }

        test "io_uring - basic SET/GET works" {
            r set mykey myvalue
            assert_equal "myvalue" [r get mykey]
        }

        test "io_uring - pipeline works" {
            set pipe [r pipeline]
            for {set i 0} {$i < 100} {incr i} {
                $pipe set "key:$i" "value:$i"
            }
            $pipe exec

            for {set i 0} {$i < 100} {incr i} {
                assert_equal "value:$i" [r get "key:$i"]
            }
        }

        test "io_uring - multiple clients" {
            set clients {}
            for {set i 0} {$i < 10} {incr i} {
                set rd [redis_deferring_client]
                lappend clients $rd
            }

            foreach rd $clients {
                $rd set testkey testval
            }

            foreach rd $clients {
                $rd read
            }

            assert_equal "testval" [r get testkey]

            foreach rd $clients {
                $rd close
            }
        }

        test "io_uring - event loop API name" {
            set info [r info server]
            # When compiled with io_uring, the multiplexing API should report io_uring
            if {[io_uring_enabled]} {
                # The API could be "io_uring" or "io_uring+epoll_fallback" depending on kernel
                set ok [expr {[string match "*multiplexing_api:io_uring*" $info]}]
                # It's also ok if it fell back to epoll on older kernels
                if {!$ok} {
                    set ok [expr {[string match "*multiplexing_api:epoll*" $info]}]
                }
                assert {$ok}
            }
        }
    }

    # Test with io_uring batch writes
    if {[io_uring_enabled]} {
        start_server {overrides {io-uring-batch-writes yes}} {
            test "io_uring batch writes - bulk write operations" {
                set pipe [r pipeline]
                for {set i 0} {$i < 1000} {incr i} {
                    $pipe set "bw:$i" [string repeat "x" 100]
                }
                $pipe exec

                for {set i 0} {$i < 1000} {incr i} {
                    assert_equal [string repeat "x" 100] [r get "bw:$i"]
                }
            }
        }
    }
}
