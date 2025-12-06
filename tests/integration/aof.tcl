source tests/support/aofmanifest.tcl
set defaults { appendonly {yes} appendfilename {appendonly.aof} appenddirname {appendonlydir} auto-aof-rewrite-percentage {0}}
set server_path [tmpdir server.aof]
set aof_dirname "appendonlydir"
set aof_basename "appendonly.aof"
set aof_dirpath "$server_path/$aof_dirname"
set aof_base_file "$server_path/$aof_dirname/${aof_basename}.1$::base_aof_sufix$::aof_format_suffix"
set aof_file "$server_path/$aof_dirname/${aof_basename}.1$::incr_aof_sufix$::aof_format_suffix"
set aof_manifest_file "$server_path/$aof_dirname/$aof_basename$::manifest_suffix"

tags {"aof external:skip"} {
    # # Server can start when aof-load-truncated is set to yes and AOF
    # # is truncated, with an incomplete MULTI block.
    # create_aof $aof_dirpath $aof_file {
    #     append_to_aof [formatCommand set foo hello]
    #     append_to_aof [formatCommand multi]
    #     append_to_aof [formatCommand set bar world]
    # }

    # create_aof_manifest $aof_dirpath $aof_manifest_file {
    #     append_to_manifest "file appendonly.aof.1.incr.aof seq 1 type i\n"
    # }

    # start_server_aof [list dir $server_path aof-load-truncated yes] {
    #     test "Unfinished MULTI: Server should start if load-truncated is yes" {
    #         assert_equal 1 [is_alive [srv pid]]
    #     }
    # }

    # ## Should also start with truncated AOF without incomplete MULTI block.
    # create_aof $aof_dirpath $aof_file {
    #     append_to_aof [formatCommand incr foo]
    #     append_to_aof [formatCommand incr foo]
    #     append_to_aof [formatCommand incr foo]
    #     append_to_aof [formatCommand incr foo]
    #     append_to_aof [formatCommand incr foo]
    #     append_to_aof [string range [formatCommand incr foo] 0 end-1]
    # }

    # start_server_aof [list dir $server_path aof-load-truncated yes] {
    #     test "Short read: Server should start if load-truncated is yes" {
    #         assert_equal 1 [is_alive [srv pid]]
    #     }

    #     test "Truncated AOF loaded: we expect foo to be equal to 5" {
    #         set client [redis [srv host] [srv port] 0 $::tls]
    #         wait_done_loading $client
    #         assert {[$client get foo] eq "5"}
    #     }

    #     test "Append a new command after loading an incomplete AOF" {
    #         $client incr foo
    #     }
    # }

    # # Now the AOF file is expected to be correct
    # start_server_aof [list dir $server_path aof-load-truncated yes] {
    #     test "Short read + command: Server should start" {
    #         assert_equal 1 [is_alive [srv pid]]
    #     }

    #     test "Truncated AOF loaded: we expect foo to be equal to 6 now" {
    #         set client [redis [srv host] [srv port] 0 $::tls]
    #         wait_done_loading $client
    #         assert {[$client get foo] eq "6"}
    #     }
    # }

    # ## Test that the server exits when the AOF contains a format error
    # create_aof $aof_dirpath $aof_file {
    #     append_to_aof [formatCommand set foo hello]
    #     append_to_aof "!!!"
    #     append_to_aof [formatCommand set foo hello]
    # }

    # start_server_aof_ex [list dir $server_path aof-load-truncated yes] [list wait_ready false] {
    #     test "Bad format: Server should have logged an error" {
    #         wait_for_log_messages 0 {"*Bad file format reading the append only file*"} 0 10 1000
    #     }
    # }

    # ## Test the server doesn't start when the AOF contains an unfinished MULTI
    # create_aof $aof_dirpath $aof_file {
    #     append_to_aof [formatCommand set foo hello]
    #     append_to_aof [formatCommand multi]
    #     append_to_aof [formatCommand set bar world]
    # }

    # start_server_aof_ex [list dir $server_path aof-load-truncated no] [list wait_ready false] {
    #     test "Unfinished MULTI: Server should have logged an error" {
    #         wait_for_log_messages 0 {"*Unexpected end of file reading the append only file*"} 0 10 1000
    #     }
    # }

    # ## Test that the server exits when the AOF contains a short read
    # create_aof $aof_dirpath $aof_file {
    #     append_to_aof [formatCommand set foo hello]
    #     append_to_aof [string range [formatCommand set bar world] 0 end-1]
    # }

    # start_server_aof_ex [list dir $server_path aof-load-truncated no] [list wait_ready false] {
    #     test "Short read: Server should have logged an error" {
    #         wait_for_log_messages 0 {"*Unexpected end of file reading the append only file*"} 0 10 1000
    #     }
    # }

    # ## Test that redis-check-aof indeed sees this AOF is not valid
    # test "Short read: Utility should confirm the AOF is not valid" {
    #     catch {
    #         exec src/redis-check-aof $aof_manifest_file
    #     } result
    #     assert_match "*not valid*" $result
    # }

    # test "Short read: Utility should show the abnormal line num in AOF" {
    #     create_aof $aof_dirpath $aof_file {
    #         append_to_aof [formatCommand set foo hello]
    #         append_to_aof "!!!"
    #     }

    #     catch {
    #         exec src/redis-check-aof $aof_manifest_file
    #     } result
    #     assert_match "*ok_up_to_line=8*" $result
    # }

    # test "Short read: Utility should be able to fix the AOF" {
    #     set result [exec src/redis-check-aof --fix $aof_manifest_file << "y\n"]
    #     assert_match "*Successfully truncated AOF*" $result
    # }

    # ## Test that the server can be started using the truncated AOF
    # start_server_aof [list dir $server_path aof-load-truncated no] {
    #     test "Fixed AOF: Server should have been started" {
    #         assert_equal 1 [is_alive [srv pid]]
    #     }

    #     test "Fixed AOF: Keyspace should contain values that were parseable" {
    #         set client [redis [srv host] [srv port] 0 $::tls]
    #         wait_done_loading $client
    #         assert_equal "hello" [$client get foo]
    #         assert_equal "" [$client get bar]
    #     }
    # }

    # ## Test that SPOP (that modifies the client's argc/argv) is correctly free'd
    # create_aof $aof_dirpath $aof_file {
    #     append_to_aof [formatCommand sadd set foo]
    #     append_to_aof [formatCommand sadd set bar]
    #     append_to_aof [formatCommand spop set]
    # }

    # start_server_aof [list dir $server_path aof-load-truncated no] {
    #     test "AOF+SPOP: Server should have been started" {
    #         assert_equal 1 [is_alive [srv pid]]
    #     }

    #     test "AOF+SPOP: Set should have 1 member" {
    #         set client [redis [srv host] [srv port] 0 $::tls]
    #         wait_done_loading $client
    #         assert_equal 1 [$client scard set]
    #     }
    # }

    # ## Uses the alsoPropagate() API.
    # create_aof $aof_dirpath $aof_file {
    #     append_to_aof [formatCommand sadd set foo]
    #     append_to_aof [formatCommand sadd set bar]
    #     append_to_aof [formatCommand sadd set gah]
    #     append_to_aof [formatCommand spop set 2]
    # }

    # start_server_aof [list dir $server_path] {
    #     test "AOF+SPOP: Server should have been started" {
    #         assert_equal 1 [is_alive [srv pid]]
    #     }

    #     test "AOF+SPOP: Set should have 1 member" {
    #         set client [redis [srv host] [srv port] 0 $::tls]
    #         wait_done_loading $client
    #         assert_equal 1 [$client scard set]
    #     }
    # }

    # ## Test that PEXPIREAT is loaded correctly
    # create_aof $aof_dirpath $aof_file {
    #     append_to_aof [formatCommand rpush list foo]
    #     append_to_aof [formatCommand pexpireat list 1000]
    #     append_to_aof [formatCommand rpush list bar]
    # }

    # start_server_aof [list dir $server_path aof-load-truncated no] {
    #     test "AOF+EXPIRE: Server should have been started" {
    #         assert_equal 1 [is_alive [srv pid]]
    #     }

    #     test "AOF+EXPIRE: List should be empty" {
    #         set client [redis [srv host] [srv port] 0 $::tls]
    #         wait_done_loading $client
    #         assert_equal 0 [$client llen list]
    #     }
    # }

    # start_server {overrides {appendonly {yes}}} {
    #     test {Redis should not try to convert DEL into EXPIREAT for EXPIRE -1} {
    #         r set x 10
    #         r expire x -1
    #     }
    # }

    start_server {tags {"tsan:skip"} overrides {appendonly {yes} appendfsync always}} {
        test {AOF fsync always barrier issue} {
            set rd [redis_deferring_client]
            # Set a sleep when aof is flushed, so that we have a chance to look
            # at the aof size and detect if the response of an incr command
            # arrives before the data was written (and hopefully fsynced)
            # We create a big reply, which will hopefully not have room in the
            # socket buffers, and will install a write handler, then we sleep
            # a big and issue the incr command, hoping that the last portion of
            # the output buffer write, and the processing of the incr will happen
            # in the same event loop cycle.
            # Since the socket buffers and timing are unpredictable, we fuzz this
            # test with slightly different sizes and sleeps a few times.
            for {set i 0} {$i < 10} {incr i} {
                r debug aof-flush-sleep 0
                r del x
                r setrange x [expr {int(rand()*5000000)+10000000}] x
                r debug aof-flush-sleep 500000
                set aof [get_last_incr_aof_path r]
                set size1 [file size $aof]
                $rd get x
                after [expr {int(rand()*30)}]
                $rd incr new_value
                $rd read
                $rd read
                set size2 [file size $aof]
                assert {$size1 != $size2}
            }
        }
    }
}
