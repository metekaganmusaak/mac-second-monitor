package com.macsecondmonitor.client.ui

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.preference.ListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceFragmentCompat
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.snackbar.Snackbar
import com.macsecondmonitor.client.BuildConfig
import com.macsecondmonitor.client.R
import com.macsecondmonitor.client.data.AppSettings

class SettingsActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)
        val root = findViewById<android.view.View>(R.id.root)
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.updatePadding(top = bars.top, bottom = bars.bottom)
            insets
        }
        findViewById<MaterialToolbar>(R.id.toolbar).apply {
            setTitle(R.string.settings_title)
            setNavigationIcon(androidx.appcompat.R.drawable.abc_ic_ab_back_material)
            setNavigationOnClickListener { finish() }
        }
        if (savedInstanceState == null) {
            supportFragmentManager.beginTransaction().replace(R.id.settingsContainer, SettingsFragment()).commit()
        }
    }

    class SettingsFragment : PreferenceFragmentCompat() {
        override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
            setPreferencesFromResource(R.xml.preferences, rootKey)

            findPreference<ListPreference>(AppSettings.PREF_LANGUAGE)?.apply {
                entryValues = resources.getStringArray(R.array.language_values)
                entries = arrayOf(getString(R.string.settings_language_system)) + resources.getStringArray(R.array.language_native_names)
                // Exact tag first (pt-BR, zh-CN), then the bare language (tr-TR → tr).
                val current = AppCompatDelegate.getApplicationLocales()[0]?.toLanguageTag()
                val values = entryValues.map { it.toString() }
                value = current?.let { tag ->
                    values.firstOrNull { it.equals(tag, ignoreCase = true) }
                        ?: values.firstOrNull { it.substringBefore('-').equals(tag.substringBefore('-'), ignoreCase = true) }
                } ?: "system"
                setOnPreferenceChangeListener { _, newValue ->
                    val tag = newValue as String
                    AppCompatDelegate.setApplicationLocales(
                        if (tag == "system") LocaleListCompat.getEmptyLocaleList() else LocaleListCompat.forLanguageTags(tag),
                    )
                    true
                }
            }

            findPreference<Preference>(AppSettings.PREF_FORGET)?.setOnPreferenceClickListener {
                MaterialAlertDialogBuilder(requireContext())
                    .setTitle(R.string.settings_forget)
                    .setMessage(R.string.settings_forget_summary)
                    .setPositiveButton(R.string.settings_forget) { _, _ ->
                        AppSettings(requireContext()).forgetPairings()
                        Snackbar.make(requireView(), R.string.settings_forget_done, Snackbar.LENGTH_SHORT).show()
                    }
                    .setNegativeButton(R.string.pairing_cancel, null)
                    .show()
                true
            }

            // Left-to-right mark: keeps "0.1.0" in one piece in right-to-left languages.
            findPreference<Preference>(AppSettings.PREF_VERSION)?.summary = "\u200E" + BuildConfig.VERSION_NAME
        }
    }
}
