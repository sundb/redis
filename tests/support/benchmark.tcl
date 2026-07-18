proc redisbenchmark_tls_config {testsdir} {
    set tlsdir [file join $testsdir tls]
    set cert [file join $tlsdir client.crt]
    set key [file join $tlsdir client.key]
    set cacert [file join $tlsdir ca.crt]

    if {$::tls} {
        return [list --tls --cert $cert --key $key --cacert $cacert]
    } else {
        return {}
    }
}

# When running under ThreadSanitizer, redis-benchmark must load the same
# suppressions file as the server (it is exec'd separately and otherwise gets
# no TSAN_OPTIONS). Returns an `env`-prefix list, or empty when not under tsan.
proc redisbenchmark_tsan_prefix {} {
    if {$::tsan} {
        return [list /usr/bin/env "TSAN_OPTIONS=allocator_may_return_null=1,detect_deadlocks=0,suppressions=src/tsan.sup"]
    }
    return {}
}

proc redisbenchmark {host port {opts {}}} {
    set cmd [list {*}[redisbenchmark_tsan_prefix] src/redis-benchmark -h $host -p $port]
    lappend cmd {*}[redisbenchmark_tls_config "tests"]
    lappend cmd {*}$opts
    return $cmd
}

proc redisbenchmarkuri {host port {opts {}}} {
    set cmd [list {*}[redisbenchmark_tsan_prefix] src/redis-benchmark -u redis://$host:$port]
    lappend cmd {*}[redisbenchmark_tls_config "tests"]
    lappend cmd {*}$opts
    return $cmd
}

proc redisbenchmarkuriuserpass {host port user pass {opts {}}} {
    set cmd [list {*}[redisbenchmark_tsan_prefix] src/redis-benchmark -u redis://$user:$pass@$host:$port]
    lappend cmd {*}[redisbenchmark_tls_config "tests"]
    lappend cmd {*}$opts
    return $cmd
}
