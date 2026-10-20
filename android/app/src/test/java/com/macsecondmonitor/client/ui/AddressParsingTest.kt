package com.macsecondmonitor.client.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AddressParsingTest {
    @Test
    fun parsesHostsAndPorts() {
        assertEquals("192.168.1.20" to 7100, MainActivity.parseAddress(" 192.168.1.20 "))
        assertEquals("mac.local" to 7300, MainActivity.parseAddress("mac.local:7300"))
        assertEquals("fe80::1" to 7100, MainActivity.parseAddress("[fe80::1]"))
        assertEquals("fe80::1" to 8000, MainActivity.parseAddress("[fe80::1]:8000"))
        assertNull(MainActivity.parseAddress(""))
        assertNull(MainActivity.parseAddress("host:abc"))
    }
}
