package com.macsecondmonitor.client.data

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import androidx.preference.PreferenceManager
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

data class RecentHost(val name: String, val address: String, val port: Int, val lastUsed: Long)

/** Persistent state: identity, pairing tokens, recent hosts and user preferences. */
class AppSettings(context: Context) {
    private val state: SharedPreferences = context.getSharedPreferences("state", Context.MODE_PRIVATE)
    private val preferences: SharedPreferences = PreferenceManager.getDefaultSharedPreferences(context)

    val deviceId: String
        get() = state.getString(KEY_DEVICE_ID, null) ?: UUID.randomUUID().toString().also {
            state.edit { putString(KEY_DEVICE_ID, it) }
        }

    val showStats: Boolean get() = preferences.getBoolean(PREF_SHOW_STATS, false)
    val autoConnectUsb: Boolean get() = preferences.getBoolean(PREF_AUTO_USB, true)
    val oneFingerScroll: Boolean get() = preferences.getBoolean(PREF_ONE_FINGER_SCROLL, false)
    val swapControlCommand: Boolean get() = preferences.getBoolean(PREF_SWAP_CTRL_CMD, false)
    val showMenuButton: Boolean get() = preferences.getBoolean(PREF_MENU_BUTTON, true)

    fun setShowStats(value: Boolean) = preferences.edit { putBoolean(PREF_SHOW_STATS, value) }

    /** Tokens are looked up by host name (from discovery or WELCOME) and by address. */
    fun token(hostName: String?, address: String): String? =
        hostName?.let { state.getString("token.name.$it", null) } ?: state.getString("token.addr.$address", null)

    fun saveToken(hostName: String, address: String, token: String) = state.edit {
        putString("token.name.$hostName", token)
        putString("token.addr.$address", token)
    }

    /** Stored like the token for 127.0.0.1, so USB connections present it in HELLO. */
    fun saveUsbSecret(secret: String) = state.edit {
        putString("token.addr.127.0.0.1", secret)
    }

    fun forgetPairings() = state.edit {
        state.all.keys.filter { it.startsWith("token.") }.forEach(::remove)
    }

    val recentHosts: List<RecentHost>
        get() {
            val array = runCatching { JSONArray(state.getString(KEY_RECENT, "[]")) }.getOrDefault(JSONArray())
            return (0 until array.length()).mapNotNull { index ->
                array.optJSONObject(index)?.let {
                    RecentHost(it.optString("name"), it.optString("address"), it.optInt("port"), it.optLong("lastUsed"))
                }
            }.sortedByDescending { it.lastUsed }
        }

    fun rememberHost(name: String, address: String, port: Int) {
        val hosts = recentHosts.filter { it.address != address || it.port != port } +
            RecentHost(name, address, port, System.currentTimeMillis())
        val array = JSONArray()
        hosts.sortedByDescending { it.lastUsed }.take(MAX_RECENT).forEach {
            array.put(JSONObject().put("name", it.name).put("address", it.address).put("port", it.port).put("lastUsed", it.lastUsed))
        }
        state.edit { putString(KEY_RECENT, array.toString()) }
    }

    companion object {
        private const val KEY_DEVICE_ID = "deviceId"
        private const val KEY_RECENT = "recentHosts"
        private const val MAX_RECENT = 5

        const val PREF_SHOW_STATS = "show_stats"
        const val PREF_AUTO_USB = "auto_connect_usb"
        const val PREF_ONE_FINGER_SCROLL = "one_finger_scroll"
        const val PREF_SWAP_CTRL_CMD = "swap_ctrl_cmd"
        const val PREF_MENU_BUTTON = "show_menu_button"
        const val PREF_LANGUAGE = "language"
        const val PREF_FORGET = "forget_pairings"
        const val PREF_VERSION = "version"
    }
}
