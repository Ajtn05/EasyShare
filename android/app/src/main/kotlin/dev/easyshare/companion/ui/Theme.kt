package dev.easyshare.companion.ui

import android.content.Context
import android.content.res.Configuration
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.widget.Button
import android.widget.LinearLayout
import android.widget.Space
import android.widget.TextView

/**
 * Easy Share's palette. One instance per appearance, picked from the system
 * dark-mode setting, so the companion follows the phone the way the Mac side
 * follows the Mac. The dark values match the macOS sheet's dark palette.
 */
class Palette(
    val background: Int,
    val surface: Int,
    val ink: Int,
    val muted: Int,
    val primary: Int,
    /** Text drawn on top of a filled `primary` button. */
    val onPrimary: Int,
    val primarySurface: Int,
    val success: Int,
    val successSurface: Int,
    val alert: Int,
    val alertSurface: Int,
    val systemBarsLight: Boolean,
)

private val LIGHT = Palette(
    background = 0xfff6f7fb.toInt(),
    surface = 0xffffffff.toInt(),
    ink = 0xff172033.toInt(),
    muted = 0xff64718a.toInt(),
    primary = 0xff315cf5.toInt(),
    onPrimary = 0xffffffff.toInt(),
    primarySurface = 0xffedf1ff.toInt(),
    success = 0xff1f9d66.toInt(),
    successSurface = 0xffeaf8f0.toInt(),
    alert = 0xffd05a3b.toInt(),
    alertSurface = 0xfffff1ed.toInt(),
    systemBarsLight = true,
)

private val DARK = Palette(
    background = 0xff0f131b.toInt(),
    surface = 0xff1a1f2b.toInt(),
    ink = 0xffeef2f8.toInt(),
    muted = 0xff97a3b8.toInt(),
    primary = 0xff7692ff.toInt(),
    // The dark-mode brand blue is light enough that white text on it would
    // fall below a readable contrast ratio; ink-on-blue is the legible pair.
    onPrimary = 0xff0f131b.toInt(),
    primarySurface = 0xff252e4b.toInt(),
    success = 0xff46d493.toInt(),
    successSurface = 0xff1c3428.toInt(),
    alert = 0xffff8b66.toInt(),
    alertSurface = 0xff47251f.toInt(),
    systemBarsLight = false,
)

val Context.isDarkMode: Boolean
    get() = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
        Configuration.UI_MODE_NIGHT_YES

val Context.colors: Palette get() = if (isDarkMode) DARK else LIGHT

/** A shared corner-radius scale (dp) so cards, chips, and sheets read as one system. */
object Radius {
    const val CHIP = 14
    const val CARD = 14
    const val SHEET = 22
}

fun Context.dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

fun Context.rounded(color: Int, radius: Int, stroke: Int? = null) = GradientDrawable().apply {
    setColor(color)
    cornerRadius = dp(radius).toFloat()
    stroke?.let { setStroke(dp(1), it) }
}

fun Context.oval(color: Int) = GradientDrawable().apply {
    shape = GradientDrawable.OVAL
    setColor(color)
}

fun Context.brandText(value: String, size: Float, color: Int, style: Int = Typeface.NORMAL) = TextView(this).apply {
    text = value
    textSize = size
    setTextColor(color)
    typeface = Typeface.create(Typeface.DEFAULT, style)
}

/** An uppercase, letter-spaced label in the brand color — the eyebrow above a modal's headline. */
fun Context.eyebrowText(value: String) = brandText(value, 11f, colors.primary, Typeface.BOLD).apply {
    letterSpacing = 0.08f
}

/** An uppercase, letter-spaced divider between sections of a longer screen. */
fun Context.sectionLabel(value: String) = brandText(value, 11f, colors.muted, Typeface.BOLD).apply {
    letterSpacing = 0.08f
}

fun Context.verticalSpace(height: Int) = Space(this).apply { minimumHeight = dp(height) }
fun Context.horizontalSpace(width: Int) = Space(this).apply { minimumWidth = dp(width) }

fun Context.matchParent(top: Int = 0, height: Int = LinearLayout.LayoutParams.WRAP_CONTENT) =
    LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, if (height > 0) dp(height) else height).apply {
        topMargin = dp(top)
    }

/** A full-bleed, non-all-caps action button — the one button style Easy Share uses everywhere. */
fun Context.brandButton(label: String, color: Int, textColor: Int, strokeColor: Int? = null) = Button(this).apply {
    text = label
    isAllCaps = false
    textSize = 15f
    typeface = Typeface.DEFAULT_BOLD
    setTextColor(textColor)
    background = rounded(color, Radius.CHIP, strokeColor)
    minHeight = 0
    minimumHeight = 0
    setPadding(dp(18), 0, dp(18), 0)
}
