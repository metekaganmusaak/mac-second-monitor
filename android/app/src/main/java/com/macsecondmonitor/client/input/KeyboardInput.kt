package com.macsecondmonitor.client.input

import android.annotation.SuppressLint
import android.content.Context
import android.text.InputType
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import com.macsecondmonitor.client.protocol.HidUsage
import com.macsecondmonitor.client.protocol.InputEvent

/** Hardware keyboard keys → KEY events with HID usages. */
class HardwareKeyboard(private val sink: (InputEvent) -> Unit) {
    var swapControlCommand = false

    /** Returns true if the event was forwarded to the Mac. */
    fun handle(event: KeyEvent): Boolean {
        if (event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_UP) return false
        // Volume, back and similar system keys stay with Android.
        if (event.isSystem && event.keyCode != KeyEvent.KEYCODE_ESCAPE) return false
        val usage = HidUsage.usage(event.keyCode, swapControlCommand) ?: return false
        val action = if (event.action == KeyEvent.ACTION_DOWN) InputEvent.KEY_DOWN else InputEvent.KEY_UP
        sink(InputEvent.Key(action, usage, HidUsage.modifiers(event.metaState, swapControlCommand)))
        return true
    }
}

/**
 * Invisible view that owns the soft keyboard. Committed text becomes TEXT events; delete and
 * enter become key presses. Suggestions are disabled so the IME commits as you type.
 */
@SuppressLint("ViewConstructor") // Created in code only.
class SoftKeyboardView(context: Context, private val sink: (InputEvent) -> Unit) : View(context) {
    init {
        isFocusable = true
        isFocusableInTouchMode = true
    }

    val isShowing: Boolean get() = hasFocus()

    fun show() {
        requestFocus()
        context.getSystemService(InputMethodManager::class.java)?.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
    }

    fun hide() {
        context.getSystemService(InputMethodManager::class.java)?.hideSoftInputFromWindow(windowToken, 0)
        clearFocus()
    }

    override fun onCheckIsTextEditor() = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_ACTION_NONE
        return object : BaseInputConnection(this, false) {
            override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean {
                // The composing part was already typed; send only what changed.
                replaceComposing(text.toString())
                composing = ""
                return true
            }

            override fun setComposingText(text: CharSequence, newCursorPosition: Int): Boolean {
                // Some IMEs compose even with suggestions off; type each composition step's
                // changes so typing stays live.
                replaceComposing(text.toString())
                composing = text.toString()
                return true
            }

            override fun finishComposingText(): Boolean {
                composing = ""
                return true
            }

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                repeat(beforeLength.coerceAtMost(64)) { tap(HidUsage.BACKSPACE) }
                return true
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean {
                val usage = HidUsage.usage(event.keyCode) ?: return super.sendKeyEvent(event)
                val action = if (event.action == KeyEvent.ACTION_DOWN) InputEvent.KEY_DOWN else InputEvent.KEY_UP
                sink(InputEvent.Key(action, usage, HidUsage.modifiers(event.metaState)))
                return true
            }

            override fun performEditorAction(actionCode: Int): Boolean {
                tap(HidUsage.RETURN)
                return true
            }
        }
    }

    private var composing = ""

    /** Turns what is on the Mac (`composing`) into [text] with the fewest key presses. */
    private fun replaceComposing(text: String) {
        val previous = composing
        val common = previous.commonPrefixWith(text).length
        repeat(previous.length - common) { tap(HidUsage.BACKSPACE) }
        sendText(text.substring(common))
    }

    private fun sendText(text: String) {
        if (text.isEmpty()) return
        // Newlines are Return presses so they work in every app.
        val parts = text.split('\n')
        parts.forEachIndexed { index, part ->
            if (part.isNotEmpty()) sink(InputEvent.Text(part))
            if (index < parts.lastIndex) tap(HidUsage.RETURN)
        }
    }

    private fun tap(usage: Int) {
        sink(InputEvent.Key(InputEvent.KEY_DOWN, usage, 0))
        sink(InputEvent.Key(InputEvent.KEY_UP, usage, 0))
    }
}
