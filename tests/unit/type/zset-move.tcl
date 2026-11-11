# ZMOVE, BZMOVE and ZMOVEMEMBER.
#
# Servers started by the test suite run with the assertions on the keysizes
# histograms and on the per-slot allocation sizes turned on, so every command
# issued here also verifies the bookkeeping of both keys.
set zmove_overrides {}
if {!$::external} {set zmove_overrides {key-memory-histograms yes}}

start_server [list tags {"zset"} overrides $zmove_overrides] {
    if {!$::external} {
        r debug keysizes-hist-assert 1
        r debug allocsize-slots-assert 1
    }

    # Create a sorted set having the given encoding, which an existing key
    # retains as long as it doesn't grow, whatever the limits are set to later.
    proc create_zset {key encoding items} {
        r del $key
        if {$encoding eq "listpack"} {
            r config set zset-max-listpack-entries 128
        } else {
            r config set zset-max-listpack-entries 0
        }
        r zadd $key {*}$items
        assert_encoding $encoding $key
    }

    proc zset_content {key} {
        r zrange $key 0 -1 withscores
    }

    foreach src {listpack btree} {
    foreach dst {listpack btree} {
        test "ZMOVE MIN and MAX - $src to $dst" {
            create_zset src{t} $src {1 a 2 b 2 c 3 d 4 e 5 f}
            create_zset dst{t} $dst {0 x 9 b}

            assert_equal {{a 1}} [r zmove src{t} dst{t} min]
            assert_equal {{f 5}} [r zmove src{t} dst{t} max]
            assert_equal {b 2 c 2 d 3 e 4} [zset_content src{t}]
            # Members come in the order they are popped, and the score of a
            # member the destination already has is overwritten.
            assert_equal {{b 2} {c 2}} [r zmove src{t} dst{t} min count 2]
            assert_equal {{e 4} {d 3}} [r zmove src{t} dst{t} max count 10]
            assert_equal 0 [r exists src{t}]
            assert_equal {x 0 a 1 b 2 c 2 d 3 e 4 f 5} [zset_content dst{t}]
            assert_encoding $dst dst{t}
        }

        test "ZMOVE BYSCORE - $src to $dst" {
            create_zset src{t} $src {1 a 2 b 2 c 2 d 3 e 4 f 5 g}
            create_zset dst{t} $dst {0 x 9 c}

            foreach {min max} {6 +inf -inf 0 3 2 (2 (3 (5 5} {
                assert_equal {} [r zmove src{t} dst{t} byscore $min $max]
            }
            # COUNT can stop in the middle of members having the same score.
            assert_equal {{b 2} {c 2}} [r zmove src{t} dst{t} byscore 2 4 count 2]
            assert_equal {{d 2} {e 3}} [r zmove src{t} dst{t} byscore (1 (4]
            assert_equal {{g 5}} [r zmove src{t} dst{t} byscore (4 +inf count 5]
            assert_equal {a 1 f 4} [zset_content src{t}]
            assert_equal {{a 1} {f 4}} [r zmove src{t} dst{t} byscore -inf +inf]
            assert_equal 0 [r exists src{t}]
            assert_equal {x 0 a 1 b 2 c 2 d 2 e 3 f 4 g 5} [zset_content dst{t}]
            assert_encoding $dst dst{t}
        }

        test "ZMOVEMEMBER - $src to $dst" {
            create_zset src{t} $src {1 a 2 b 3 c 4 d 5 e 6 f}
            create_zset dst{t} $dst {0 x 9 b 3 c}

            # Members are replied in the order they are given. Those missing
            # from the source are skipped, as a repeated member is.
            assert_equal {{d 4} {a 1}} [r zmovemember src{t} dst{t} members 4 d nosuch a d]
            assert_equal {} [r zmovemember src{t} dst{t} members 2 nosuch a]
            # NX leaves in the source the members the destination has.
            assert_equal {{e 5}} [r zmovemember src{t} dst{t} nx members 3 b c e]
            assert_equal {b 2 c 3 f 6} [zset_content src{t}]
            # XX leaves in the source the members the destination lacks.
            assert_equal {{b 2} {c 3}} [r zmovemember src{t} dst{t} members 3 f b c xx]
            assert_equal {f 6} [zset_content src{t}]
            assert_equal {x 0 a 1 b 2 c 3 d 4 e 5} [zset_content dst{t}]
            assert_equal {{f 6}} [r zmovemember src{t} dst{t} members 1 f]
            assert_equal 0 [r exists src{t}]
            assert_encoding $dst dst{t}
        }
    }
    }

    test {ZMOVE with large batches} {
        r config set zset-max-listpack-entries 128
        # Two members per score, as (member, score) pairs in rank order.
        set all {}
        set items {}
        for {set i 0} {$i < 6000} {incr i} {
            set member [format "m%04d" $i]
            lappend all [list $member [expr {$i / 2}]]
            lappend items [expr {$i / 2}] $member
        }
        foreach {selection first last reverse} {
            {min count 2500}     0    2499 0
            {max count 2500}     3500 5999 1
            {byscore 1000 (2250} 2000 4499 0
        } {
            r del src{t} dst{t}
            r zadd src{t} {*}$items
            set moved [lrange $all $first $last]
            set left [concat [lrange $all 0 $first-1] [lrange $all $last+1 end]]

            # A destination that is created is sized for the batch.
            set reply [r zmove src{t} dst{t} {*}$selection]
            assert_equal [expr {$reverse ? [lreverse $moved] : $moved}] $reply
            assert_encoding btree dst{t}
            assert_equal [concat {*}$moved] [zset_content dst{t}]
            assert_equal [concat {*}$left] [zset_content src{t}]
            assert_equal 1250 [r zrank dst{t} [lindex $moved 1250 0]]
            assert_equal {} [r zscore src{t} [lindex $moved 1250 0]]

            # Move what is left into the, now existing, destination.
            assert_equal $left [r zmove src{t} dst{t} byscore -inf +inf]
            assert_equal 0 [r exists src{t}]
            assert_equal [concat {*}$all] [zset_content dst{t}]
        }
    }

    foreach {encoding size} {listpack 100 btree 1000} {
        test "ZMOVE and ZMOVEMEMBER fuzzing - $encoding" {
            # What is moved is predicted by reading both keys first, and both
            # are compared with a model of their content afterwards.
            proc zset_pairs {flat} {
                set pairs {}
                foreach {member score} $flat {lappend pairs [list $member $score]}
                return $pairs
            }
            r config set zset-max-listpack-entries [expr {$encoding eq "listpack" ? 128 : 8}]
            for {set round 0} {$round < 5} {incr round} {
                r del src{t} dst{t}
                array unset msrc
                array unset mdst
                for {set i 0} {$i < $size} {incr i} {
                    set member m[randomInt [expr {$size * 2}]]
                    set msrc($member) [randomInt 50]
                    r zadd src{t} $msrc($member) $member
                    if {$i % 4 == 0} {
                        set member m[randomInt [expr {$size * 2}]]
                        set mdst($member) [randomInt 50]
                        r zadd dst{t} $mdst($member) $member
                    }
                }
                while {[array size msrc]} {
                    set count [expr {1 + [randomInt [expr {$size / 8}]]}]
                    set lo [randomInt 50]
                    set hi [expr {$lo + [randomInt 5]}]
                    switch [randomInt 6] {
                        0 {
                            set expected [r zrange src{t} 0 [expr {$count - 1}] withscores]
                            set reply [r zmove src{t} dst{t} min count $count]
                        }
                        1 {
                            set expected [r zrange src{t} 0 [expr {$count - 1}] rev withscores]
                            set reply [r zmove src{t} dst{t} max count $count]
                        }
                        2 {
                            set expected [r zrange src{t} $lo ($hi byscore withscores]
                            set reply [r zmove src{t} dst{t} byscore $lo ($hi]
                        }
                        3 {
                            set expected [r zrange src{t} ($lo +inf byscore limit 0 $count withscores]
                            set reply [r zmove src{t} dst{t} byscore ($lo +inf count $count]
                        }
                        default {
                            set cond [lindex {{} nx xx} [randomInt 3]]
                            set members {}
                            set expected {}
                            for {set i 0} {$i < $count} {incr i} {
                                set member m[randomInt [expr {$size * 2}]]
                                lappend members $member
                                if {![info exists msrc($member)] || $member in [lrange $members 0 end-1]} continue
                                if {$cond eq "nx" && [info exists mdst($member)]} continue
                                if {$cond eq "xx" && ![info exists mdst($member)]} continue
                                lappend expected $member $msrc($member)
                            }
                            set reply [r zmovemember src{t} dst{t} {*}$cond members $count {*}$members]
                        }
                    }
                    assert_equal [zset_pairs $expected] $reply
                    foreach {member score} $expected {
                        unset msrc($member)
                        set mdst($member) $score
                    }
                    assert_equal [array size msrc] [r zcard src{t}]
                    assert_equal [array size mdst] [r zcard dst{t}]
                    foreach key {src{t} dst{t}} name {msrc mdst} {
                        foreach {member score} [zset_content $key] {
                            if {[set ${name}($member)] != $score} {
                                fail "$member has score $score in $key"
                            }
                        }
                    }
                }
                assert_equal 0 [r exists src{t}]
            }
            r config set zset-max-listpack-entries 128
        }
    }

    test {ZMOVE and ZMOVEMEMBER choose the encoding of a new destination} {
        r config set zset-max-listpack-entries 4
        set long [string repeat x 100]
        r del src{t} small{t} big{t} long{t} named{t}
        r zadd src{t} 1 a 2 b 3 c 4 d 5 e 6 f 7 g 8 $long 9 i 10 j 11 k 12 l

        assert_equal {{a 1} {b 2}} [r zmove src{t} small{t} min count 2]
        assert_encoding listpack small{t}
        assert_equal {{l 12} {k 11} {j 10} {i 9} {xxx 8}} \
            [string map [list $long xxx] [r zmove src{t} big{t} max count 5]]
        assert_encoding btree big{t}
        assert_equal 100 [string length [lindex [r zrange big{t} 0 0] 0]]
        # A member too long for a listpack converts it half way.
        r zadd src{t} 5.5 $long
        assert_equal 4 [llength [r zmove src{t} long{t} byscore 4 6]]
        assert_encoding btree long{t}
        assert_equal [list d e $long f] [r zrange long{t} 0 -1]
        r zadd src{t} 1 a 2 b
        assert_equal {{g 7} {c 3}} [r zmovemember src{t} named{t} members 5 g c x y z]
        assert_encoding listpack named{t}
        assert_equal {a 1 b 2} [zset_content src{t}]
        r config set zset-max-listpack-entries 128
    }

    test {ZMOVE and ZMOVEMEMBER keep integer and binary members as they are} {
        r del src{t} dst{t} dst2{t}
        set bin "a\x00\x01z"
        r zadd src{t} 1 10 2 -5 3 007 4 $bin 5 9223372036854775807 6 1.50
        assert_encoding listpack src{t}
        assert_equal {{10 1} {-5 2}} [r zmove src{t} dst{t} min count 2]
        assert_equal [list [list 1.50 6] [list 9223372036854775807 5] [list $bin 4]] \
            [r zmove src{t} dst{t} max count 3]
        assert_equal [list 10 -5 $bin 9223372036854775807 1.50] [r zrange dst{t} 0 -1]
        assert_equal {{-5 2}} [r zmovemember dst{t} src{t} members 2 -5 007]
        assert_equal {-5 2 007 3} [zset_content src{t}]
        assert_equal [list [list $bin 4]] [r zmovemember dst{t} dst2{t} members 1 $bin]
        assert_equal [list $bin] [r zrange dst2{t} 0 -1]
    }

    test {ZMOVE, BZMOVE and ZMOVEMEMBER move nothing from a missing source or to the same key} {
        r del src{t} dst{t}
        r zadd zset{t} 1 a 2 b
        foreach args {
            {zmove min} {zmove max count 2} {zmove byscore -inf +inf}
            {bzmove min 0.01} {bzmove max 0.01 count 2} {zmovemember members 1 a}
        } {
            set args [lassign $args cmd]
            assert_equal {} [r $cmd src{t} dst{t} {*}$args]
            assert_equal {} [r $cmd zset{t} zset{t} {*}$args]
        }
        # A BZMOVE that can't block is a ZMOVE.
        r multi
        r bzmove src{t} dst{t} min 0
        assert_equal {{}} [r exec]
        assert_equal 0 [r exists src{t} dst{t}]
        assert_equal {a 1 b 2} [zset_content zset{t}]
    }

    test {ZMOVEMEMBER NX and XX against a missing destination} {
        r del src{t} dst{t}
        r zadd src{t} 1 a 2 b
        assert_equal {} [r zmovemember src{t} dst{t} xx members 2 a b]
        assert_equal 0 [r exists dst{t}]
        assert_equal {{b 2} {a 1}} [r zmovemember src{t} dst{t} nx members 2 b a]
        assert_equal 0 [r exists src{t}]
        assert_equal {a 1 b 2} [zset_content dst{t}]
    }

    test {ZMOVEMEMBER members can be named after the options} {
        r del src{t} dst{t}
        r zadd src{t} 1 NX 2 XX 3 MEMBERS 4 2
        r zadd dst{t} 9 XX
        assert_equal {{NX 1} {2 4}} [r zmovemember src{t} dst{t} members 3 NX XX 2 nx]
        assert_equal {{MEMBERS 3} {XX 2}} [r zmovemember src{t} dst{t} members 2 MEMBERS XX]
        assert_equal {NX 1 XX 2 MEMBERS 3 2 4} [zset_content dst{t}]
    }

    test {ZMOVE, BZMOVE and ZMOVEMEMBER against wrong types} {
        r del src{t} dst{t} zset{t}
        r zadd zset{t} 1 a
        r set str{t} x
        foreach args {
            {zmove min} {zmove byscore -inf +inf} {bzmove min 0} {zmovemember members 1 a}
        } {
            set args [lassign $args cmd]
            assert_error {WRONGTYPE*} {r $cmd str{t} zset{t} {*}$args}
            assert_error {WRONGTYPE*} {r $cmd zset{t} str{t} {*}$args}
            assert_error {WRONGTYPE*} {r $cmd str{t} str{t} {*}$args}
        }
        # As for LMOVE and SMOVE, nothing to move comes first.
        assert_equal {} [r zmove src{t} str{t} min]
        assert_equal {a 1} [zset_content zset{t}]
    }

    test {ZMOVE, BZMOVE and ZMOVEMEMBER with invalid arguments} {
        r del dst{t}
        r zadd src{t} 1 a 2 b
        foreach args {
            {zmove mid} {zmove min 2} {zmove min count} {zmove min count 1 2}
            {zmove min limit 1} {zmove byscore 1} {zmove byscore 1 2 3}
            {zmove byscore 1 2 count} {zmove byscore 1 2 limit 0 1}
            {bzmove byscore 1 2 0} {bzmove min 0 2} {bzmove min 0 count}
            {zmovemember members 1 a b} {zmovemember members 1 a members 1 b}
            {zmovemember nx a members} {zmovemember gt members 1 a}
        } {
            set args [lassign $args cmd]
            assert_error {ERR syntax error} {r $cmd src{t} dst{t} {*}$args}
        }
        foreach count {0 -1 1.5 abc 9223372036854775808} {
            assert_error {ERR count should be greater than 0} {r zmove src{t} dst{t} min count $count}
            assert_error {ERR count should be greater than 0} {r zmove src{t} dst{t} byscore 1 2 count $count}
            assert_error {ERR count should be greater than 0} {r bzmove src{t} dst{t} max 0 count $count}
            assert_error {ERR Number of members*} {r zmovemember src{t} dst{t} members $count a}
        }
        assert_error {ERR min or max is not a float} {r zmove src{t} dst{t} byscore a 2}
        assert_error {ERR min or max is not a float} {r zmove src{t} dst{t} byscore 1 nan}
        assert_error {ERR timeout is not a float*} {r bzmove src{t} dst{t} min abc}
        assert_error {ERR timeout is negative} {r bzmove src{t} dst{t} min -1}
        assert_error {ERR The `num-members` parameter*} {r zmovemember src{t} dst{t} members 2 a}
        assert_error {ERR The `num-members` parameter*} {r zmovemember src{t} dst{t} members 3 a nx}
        assert_error {ERR Mandatory argument MEMBERS is missing} {r zmovemember src{t} dst{t} nx xx nx}
        assert_error {ERR XX and NX*} {r zmovemember src{t} dst{t} nx members 1 a xx}
        assert_error {ERR wrong number of arguments*} {r zmove src{t} dst{t}}
        assert_error {ERR wrong number of arguments*} {r bzmove src{t} dst{t} min}
        assert_error {ERR wrong number of arguments*} {r zmovemember src{t} dst{t} members a}
        assert_equal {a 1 b 2} [zset_content src{t}]
        assert_equal 0 [r exists dst{t}]
    }

    foreach resp {3 2} {
        if {[lsearch $::denytags "resp3"] >= 0} {
            if {$resp == 3} {continue}
        } elseif {$::force_resp3} {
            if {$resp == 2} {continue}
        }
        test "ZMOVE, BZMOVE and ZMOVEMEMBER reply in RESP$resp" {
            r hello $resp
            # A score is a double in RESP3, and a bulk string in RESP2.
            if {$resp == 3} {
                set nil _
                set expected {*2 *2 $1 a ,1 *2 $1 b ,2.5}
            } else {
                set nil *-1
                set expected {*2 *2 $1 a $1 1 *2 $1 b $3 2.5}
            }
            foreach cmd {
                {zmove min count 2} {zmove byscore 1 3}
                {bzmove min 0.01 count 2} {zmovemember members 2 a b}
            } {
                set args [lassign $cmd cmd]
                r del src{t} dst{t}
                r readraw 1
                assert_equal $nil [r $cmd src{t} dst{t} {*}$args]
                r readraw 0
                r zadd src{t} 1 a 2.5 b
                r readraw 1
                set reply [list [r $cmd src{t} dst{t} {*}$args]]
                while {[llength $reply] < [llength $expected]} {lappend reply [r read]}
                r readraw 0
                assert_equal $expected [join $reply]
            }
        }
    }
    r hello 2

    test {ZMOVE and ZMOVEMEMBER signal the keys they modify} {
        r del src{t} dst{t}
        r zadd src{t} 1 a 2 b 3 c
        r zadd dst{t} 1 a 9 b
        set watcher [redis_client]
        # Nothing moves, so nothing changes.
        $watcher watch src{t} dst{t}
        r zmove src{t} dst{t} byscore 5 6
        r zmovemember src{t} dst{t} nx members 2 a b
        r zmovemember src{t} dst{t} xx members 2 c d
        $watcher multi
        $watcher ping
        assert_equal PONG [$watcher exec]
        # The destination has the moved member already, with the same score.
        $watcher watch dst{t}
        assert_equal {{a 1}} [r zmove src{t} dst{t} min]
        $watcher multi
        $watcher ping
        assert_equal PONG [$watcher exec]
        # The score of a destination member is updated.
        $watcher watch dst{t}
        assert_equal {{b 2}} [r zmovemember src{t} dst{t} members 1 b]
        $watcher multi
        $watcher ping
        assert_equal {} [$watcher exec]
        $watcher watch src{t}
        assert_equal {{c 3}} [r zmove src{t} dst{t} max]
        $watcher multi
        $watcher ping
        assert_equal {} [$watcher exec]
        $watcher close
    }

    test {ZMOVE, BZMOVE and ZMOVEMEMBER keyspace events} {
        r del src{t} dst{t}
        r config set notify-keyspace-events KA
        set rd [redis_deferring_client]
        assert_equal 1 [psubscribe $rd __keyspace@*]
        proc assert_keyspace_event {rd key event} {
            set msg [$rd read]
            assert_match "__keyspace@*:$key" [lindex $msg 2]
            assert_equal $event [lindex $msg 3]
        }
        foreach {cmd events} {
            {zmove src{t} dst{t} min}                 {src{t} zpopmin dst{t} zadd}
            {zmove src{t} dst{t} max count 2}         {src{t} zpopmax dst{t} zadd}
            {bzmove src{t} dst{t} max 0}              {src{t} zpopmax dst{t} zadd}
            {zmove src{t} dst{t} byscore 4 5}         {src{t} zremrangebyscore dst{t} zadd}
            {zmove src{t} dst{t} byscore 7 8}         {}
            {zmovemember src{t} dst{t} members 1 x}   {}
            {zmovemember src{t} dst{t} members 2 b c} {src{t} zrem src{t} del dst{t} zadd}
        } {
            if {![r exists src{t}]} {
                r zadd src{t} 1 a 2 b 3 c 4 d 5 e 6 f 7 g 8 h
                assert_keyspace_event $rd src{t} zadd
            }
            r {*}$cmd
            foreach {key event} $events {
                assert_keyspace_event $rd $key $event
            }
        }
        # The destination isn't notified when it's left as it was.
        r zadd src{t} 6 f
        assert_keyspace_event $rd src{t} zadd
        r zmove src{t} dst{t} min
        assert_keyspace_event $rd src{t} zpopmin
        assert_keyspace_event $rd src{t} del
        r zadd src{t} 1 a
        assert_keyspace_event $rd src{t} zadd
        $rd close
        r config set notify-keyspace-events {}
    }

    test {ZMOVE into a new destination serves the clients blocked on it} {
        r del src{t} dst{t}
        r zadd src{t} 1 a 2 b
        set rd [redis_deferring_client]
        $rd bzpopmin dst{t} 0
        wait_for_blocked_client
        assert_equal {{a 1} {b 2}} [r zmove src{t} dst{t} byscore -inf +inf]
        assert_equal {dst{t} a 1} [$rd read]
        assert_equal {b 2} [zset_content dst{t}]
        $rd close
    }

    foreach where {min max} {
        test "BZMOVE $where blocks until the source has members" {
            r del src{t} dst{t}
            set rd [redis_deferring_client]
            $rd bzmove src{t} dst{t} $where 0
            wait_for_blocked_client
            # The destination doesn't unblock it.
            r zadd dst{t} 0 x
            assert_equal 1 [s blocked_clients]
            r zadd src{t} 1 a 2 b 3 c
            assert_equal [expr {$where eq "min" ? {{a 1}} : {{c 3}}}] [$rd read]

            # With COUNT it's served with the members there are.
            r del src{t}
            $rd bzmove src{t} dst{t} $where 0 count 5
            wait_for_blocked_client
            r zadd src{t} 1 a 2 b
            assert_equal [expr {$where eq "min" ? {{a 1} {b 2}} : {{b 2} {a 1}}}] [$rd read]
            assert_equal 0 [r exists src{t}]
            assert_equal [expr {$where eq "min" ? {x 0 a 1 b 2} : {x 0 a 1 b 2 c 3}}] [zset_content dst{t}]
            $rd close
        }
    }

    test {BZMOVE blocked clients are served in order, one batch each} {
        r del src{t} dst{t} dst2{t}
        set rd1 [redis_deferring_client]
        set rd2 [redis_deferring_client]
        $rd1 bzmove src{t} dst{t} min 0 count 2
        wait_for_blocked_clients_count 1
        $rd2 bzmove src{t} dst2{t} min 0 count 2
        wait_for_blocked_clients_count 2
        r zadd src{t} 1 a 2 b 3 c
        assert_equal {{a 1} {b 2}} [$rd1 read]
        assert_equal {{c 3}} [$rd2 read]
        assert_equal {a 1 b 2} [zset_content dst{t}]
        assert_equal {c 3} [zset_content dst2{t}]
        $rd1 close
        $rd2 close
    }

    test {BZMOVE times out, and checks the destination once unblocked} {
        r del src{t} dst{t}
        set rd [redis_deferring_client]
        $rd bzmove src{t} dst{t} min 0.01
        assert_equal {} [$rd read]

        r set dst{t} x
        $rd bzmove src{t} dst{t} min 0
        wait_for_blocked_client
        r zadd src{t} 1 a
        assert_error {WRONGTYPE*} {$rd read}
        assert_equal {a 1} [zset_content src{t}]
        $rd close
    }

    test {ZMOVE, BZMOVE and ZMOVEMEMBER propagation} {
        r del src{t} dst{t}
        set repl [attach_to_replication_stream]
        set rd [redis_deferring_client]
        $rd bzmove src{t} dst{t} max 0 count 2
        wait_for_blocked_client
        r zadd src{t} 1 a 2 b 3 c 4 d 5 e 6 f
        assert_equal {{f 6} {e 5}} [$rd read]
        r bzmove src{t} dst{t} min 0
        # Commands that move nothing aren't propagated.
        r zmove src{t} dst{t} byscore 7 8
        r zmovemember src{t} dst{t} xx members 2 b x
        assert_error {ERR count*} {r zmove src{t} dst{t} min count 0}
        r zmove src{t} dst{t} byscore (1 3 count 1
        r zmovemember src{t} dst{t} nx members 3 f c d
        assert_replication_stream $repl {
            {select *}
            {zadd src{t} 1 a 2 b 3 c 4 d 5 e 6 f}
            {zmove src{t} dst{t} max count 2}
            {zmove src{t} dst{t} min}
            {zmove src{t} dst{t} byscore (1 3 count 1}
            {zmovemember src{t} dst{t} nx members 3 f c d}
        }
        close_replication_stream $repl
        $rd close
        assert_equal 0 [r exists src{t}]
        assert_equal {a 1 b 2 c 3 d 4 e 5 f 6} [zset_content dst{t}]
    } {} {needs:repl}
}

start_server {tags {"zset external:skip needs:debug"} overrides {appendonly yes aof-use-rdb-preamble no}} {
    test {ZMOVE, BZMOVE and ZMOVEMEMBER are replayed from the AOF} {
        r zadd src{t} 1 a 2 b 3 c 4 d 5 e 6 f
        r zadd dst{t} 9 b
        r zmove src{t} dst{t} byscore 2 3
        r zmove src{t} dst{t} max
        r bzmove src{t} dst{t} min 0
        r zmovemember src{t} dst{t} members 1 e
        r debug loadaof
        assert_equal {d 4} [r zrange src{t} 0 -1 withscores]
        assert_equal {a 1 b 2 c 3 e 5 f 6} [r zrange dst{t} 0 -1 withscores]
    }
}
