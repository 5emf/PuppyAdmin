package com.pupdates.app

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Pupdates, laid out like the Sword Art Online-style menu (original, shapes only): the window is
 * see-through (no backdrop), with a column of round icons (Compose, Updates, Whitelist, Settings)
 * beside a white card and a grey description strip under it.
 */
class MainActivity : Activity() {
    private lateinit var store: Store
    private val http: Core.Http = Core.NET
    private val pool = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private val sections = listOf("compose", "updates", "whitelist", "settings")
    private val titles = mapOf("compose" to "Compose", "updates" to "Updates", "whitelist" to "Whitelist", "settings" to "Settings")
    private val descriptions = mapOf(
        "compose" to "Write any message, add a picture, and post it to your Discord channel.",
        "updates" to "Fill in a Puppy Admin or Puppy Companion update from GitHub.",
        "whitelist" to "Choose who may post through your relay (owner only: needs the admin key).",
        "settings" to "Post straight to a webhook, or through the relay with your access key.")
    private val pages = HashMap<String, View>()
    private val icons = HashMap<String, ImageView>()
    private var section = ""

    private lateinit var scroll: ScrollView
    private lateinit var sectionLbl: TextView
    private lateinit var status: TextView
    private lateinit var strip: TextView

    // compose
    private lateinit var titleIn: EditText
    private lateinit var messageIn: EditText
    private lateinit var embedChk: CheckBox
    private lateinit var colorSpin: Spinner
    private lateinit var nameIn: EditText
    private lateinit var pingSpin: Spinner
    private lateinit var roleIn: EditText
    private lateinit var loadstringChk: CheckBox
    private lateinit var pictureLbl: TextView
    private lateinit var thumb: ImageView
    private lateinit var removePic: TextView
    private lateinit var postBtn: TextView
    private var picture: Core.Picture? = null
    private var template: String? = null
    private var info: Core.Latest? = null

    // updates / whitelist / settings
    private lateinit var latestLbl: TextView
    private lateinit var wlRelayIn: EditText
    private lateinit var adminIn: EditText
    private lateinit var adminLbl: TextView
    private lateinit var usersBox: LinearLayout
    private lateinit var newNameIn: EditText
    private lateinit var newPingChk: CheckBox
    private lateinit var newKeyLbl: TextView
    private lateinit var modeGroup: RadioGroup
    private lateinit var webhookIn: EditText
    private lateinit var webhookLbl: TextView
    private lateinit var relayIn: EditText
    private lateinit var keyIn: EditText
    private lateinit var relayLbl: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = Store(this)
        setContentView(buildUi())
        show("compose")
        say(modeText())
        handleShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShare(intent)
    }

    override fun onDestroy() {
        pool.shutdownNow()
        super.onDestroy()
    }

    // ------------------------------------------------------------------ look
    private fun dp(v: Int) = (v * resources.displayMetrics.density + 0.5f).toInt()

    private fun plate(fill: Int, stroke: Int, width: Int = 1): GradientDrawable =
        GradientDrawable().apply { setColor(fill); setStroke(dp(width), stroke) }

    private fun states(normal: Drawable, pressed: Drawable): StateListDrawable = StateListDrawable().apply {
        addState(intArrayOf(android.R.attr.state_pressed), pressed)
        addState(intArrayOf(-android.R.attr.state_enabled), plate(0xFFEEEEEF.toInt(), LINE))
        addState(intArrayOf(), normal)
    }

    private fun label(text: String, dim: Boolean = false, size: Float = 14f, bold: Boolean = false) = TextView(this).apply {
        this.text = text
        textSize = size
        setTextColor(if (dim) DIM else INK)
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun button(text: String, accent: Boolean = false, onClick: () -> Unit) = TextView(this).apply {
        this.text = text
        textSize = 14f
        gravity = Gravity.CENTER
        setPadding(dp(14), dp(9), dp(14), dp(9))
        background = if (accent) states(plate(ORANGE, ORANGE_DARK), plate(ORANGE_DARK, ORANGE_DARK))
                     else states(plate(0xFFF1F2F4.toInt(), LINE), plate(ORANGE, ORANGE_DARK))
        setTextColor(ColorStateList(arrayOf(intArrayOf(android.R.attr.state_pressed), intArrayOf(-android.R.attr.state_enabled), intArrayOf()),
            intArrayOf(Color.WHITE, DIM, if (accent) Color.WHITE else INK)))
        isClickable = true
        setOnClickListener { onClick() }
    }

    private fun field(hint: String, secret: Boolean = false, lines: Int = 1) = EditText(this).apply {
        this.hint = hint
        textSize = 14f
        setTextColor(INK)
        setHintTextColor(0xFFB4B7BE.toInt())
        background = StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_focused), plate(Color.WHITE, ORANGE))
            addState(intArrayOf(), plate(Color.WHITE, LINE))
        }
        setPadding(dp(10), dp(8), dp(10), dp(8))
        if (lines > 1) {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            minLines = lines
            gravity = Gravity.TOP or Gravity.START
        } else {
            isSingleLine = true
            inputType = if (secret) InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                        else InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
        }
    }

    private fun check(text: String, on: Boolean) = CheckBox(this).apply {
        this.text = text
        isChecked = on
        setTextColor(INK)
        buttonTintList = ColorStateList.valueOf(ORANGE)
    }

    private fun spinner(items: List<String>, chosen: String) = Spinner(this).apply {
        adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_item, items).also {
            it.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        }
        setSelection(items.indexOf(chosen).coerceAtLeast(0))
        background = plate(Color.WHITE, LINE)
        setPadding(dp(6), dp(4), dp(6), dp(4))
    }

    private fun row(vararg views: View, top: Int = 6): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).also { it.topMargin = dp(top) }
        for (v in views) addView(v)
    }

    private fun grow(v: View, left: Int = 0, weight: Float = 1f): View {
        v.layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, weight).also { it.leftMargin = dp(left) }
        return v
    }

    private fun gap(v: View, left: Int = 6): View {
        v.layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).also { it.leftMargin = dp(left) }
        return v
    }

    private fun page(vararg views: View): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(14), dp(10), dp(14), dp(10))
        for (v in views) {
            if (v.layoutParams == null) v.layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                .also { it.topMargin = dp(6) }
            addView(v)
        }
    }

    private fun drawable(name: String): Drawable = resources.getDrawable(
        when (name) {
            "compose_normal" -> R.drawable.ic_compose_normal; "compose_hover" -> R.drawable.ic_compose_hover; "compose_chosen" -> R.drawable.ic_compose_chosen
            "updates_normal" -> R.drawable.ic_updates_normal; "updates_hover" -> R.drawable.ic_updates_hover; "updates_chosen" -> R.drawable.ic_updates_chosen
            "whitelist_normal" -> R.drawable.ic_whitelist_normal; "whitelist_hover" -> R.drawable.ic_whitelist_hover; "whitelist_chosen" -> R.drawable.ic_whitelist_chosen
            "settings_normal" -> R.drawable.ic_settings_normal; "settings_hover" -> R.drawable.ic_settings_hover; "settings_chosen" -> R.drawable.ic_settings_chosen
            "picture_normal" -> R.drawable.ic_picture_normal; "picture_hover" -> R.drawable.ic_picture_hover
            "send_normal" -> R.drawable.ic_send_normal; "send_hover" -> R.drawable.ic_send_hover
            "close_normal" -> R.drawable.ic_close_normal; "close_hover" -> R.drawable.ic_close_hover
            else -> R.mipmap.ic_launcher
        }, theme)

    private fun roundIcon(name: String, size: Int, onClick: () -> Unit) = ImageView(this).apply {
        setImageDrawable(states(drawable("${name}_normal"), drawable("${name}_hover")))
        layoutParams = LinearLayout.LayoutParams(dp(size), dp(size))
        isClickable = true
        contentDescription = name
        setOnClickListener { onClick() }
    }

    // ------------------------------------------------------------------ layout
    private fun buildUi(): View {
        val metrics = resources.displayMetrics
        val cardW = minOf(metrics.widthPixels - dp(84), dp(560))
        val root = FrameLayout(this).apply { fitsSystemWindows = true }
        val line = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(6), dp(16), dp(6), dp(16))
        }
        root.addView(line, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(0, dp(52), dp(8), 0) }
        for (name in sections) {
            val icon = roundIcon(name, 52) { show(name) }
            (icon.layoutParams as LinearLayout.LayoutParams).bottomMargin = dp(10)
            icons[name] = icon
            col.addView(icon)
        }
        line.addView(col)

        val right = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        line.addView(right, LinearLayout.LayoutParams(cardW, ViewGroup.LayoutParams.MATCH_PARENT))
        val card = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; background = plate(CARD, LINE) }
        right.addView(card, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        val logo = ImageView(this).apply { setImageDrawable(drawable("logo")); layoutParams = LinearLayout.LayoutParams(dp(30), dp(30)) }
        val title = label("PUPDATES", size = 18f, bold = true)
        sectionLbl = label("", dim = true)
        val close = label("×", dim = true, size = 24f).apply { setPadding(dp(10), 0, dp(4), 0); setOnClickListener { finish() } }
        val head = row(logo, gap(title, 8), gap(sectionLbl, 6), grow(View(this)), close, top = 0).apply { setPadding(dp(12), dp(10), dp(12), 0) }
        card.addView(head)
        card.addView(View(this).apply { setBackgroundColor(ORANGE) },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(2)).also { it.setMargins(dp(12), dp(8), dp(12), 0) })
        scroll = ScrollView(this).apply { isFillViewport = true }
        card.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        status = label("", dim = true, size = 13f).apply { setPadding(dp(14), dp(4), dp(14), dp(10)) }
        card.addView(status)
        strip = label("", size = 13f).apply { setBackgroundColor(STRIP); setPadding(dp(12), dp(8), dp(12), dp(8)) }
        right.addView(strip, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).also { it.topMargin = dp(6) })

        pages["compose"] = buildCompose()
        pages["updates"] = buildUpdates()
        pages["whitelist"] = buildWhitelist()
        pages["settings"] = buildSettings()
        return root
    }

    private fun show(name: String) {
        if (section.isNotEmpty()) icons[section]?.setImageDrawable(states(drawable("${section}_normal"), drawable("${section}_hover")))
        section = name
        icons[name]?.setImageDrawable(drawable("${name}_chosen"))
        scroll.removeAllViews()
        scroll.addView(pages[name])
        scroll.scrollTo(0, 0)
        sectionLbl.text = "/ " + titles[name]
        strip.text = descriptions[name]
        if (name == "whitelist" && store.secret("admin_key").isNotEmpty() && store.get("relay_url").isNotEmpty() && usersBox.childCount == 0) refreshUsers()
    }

    private fun say(text: String, kind: Int = DIM) {
        status.text = text
        status.setTextColor(kind)
    }

    private fun modeText(): String = if (store.get("mode") == "relay") {
        if (store.secret("relay_key").isNotEmpty()) "Posting through the relay." else "Relay mode: enter your access key in Settings."
    } else {
        if (store.secret("webhook").isNotEmpty()) "Posting to your webhook." else "Save your webhook in Settings (or use the relay)."
    }

    private fun <T> bg(work: () -> T, done: (T?, String?) -> Unit) {
        pool.execute {
            val (res, err) = try {
                work() to null
            } catch (e: Core.PupError) {
                null to (e.message ?: "Failed")
            } catch (e: Exception) {
                null to Core.redact(e.toString())
            }
            main.post { if (!isDestroyed) done(res, err) }
        }
    }

    // ------------------------------------------------------------------ compose
    private fun buildCompose(): View {
        titleIn = field("Title")
        messageIn = field("Message", lines = 6)
        embedChk = check("Card (embed)", store.getBool("embed", true))
        colorSpin = spinner(Core.COLORS.keys.toList(), store.get("color", "Orange"))
        nameIn = field("Name").apply { setText(store.get("username", Core.APP)) }
        pingSpin = spinner(Core.PINGS, store.get("ping", "none"))
        roleIn = field("role id").apply { inputType = InputType.TYPE_CLASS_NUMBER; setText(store.get("role_id")) }
        loadstringChk = check("Loadstring", false)
        pictureLbl = label("No picture (PNG, JPG, GIF or WEBP up to 8 MB)", dim = true, size = 13f)
        thumb = ImageView(this).apply { adjustViewBounds = true; maxHeight = dp(90); maxWidth = dp(120) }
        removePic = button("Remove") { clearPicture() }.apply { isEnabled = false }
        postBtn = button("Post to Discord", accent = true) { post() }
        pingSpin.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) { roleIn.visibility = if (Core.PINGS[pos] == "role") View.VISIBLE else View.GONE }
            override fun onNothingSelected(p: AdapterView<*>?) {}
        }
        val picIcon = roundIcon("picture", 44) { pickPicture() }
        val picBox = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(pictureLbl)
            addView(row(button("Add picture") { pickPicture() }, gap(removePic), top = 4))
        }
        return page(
            titleIn, messageIn,
            row(embedChk, gap(label("Colour"), 12), gap(colorSpin)),
            row(label("Name"), grow(nameIn, 6)),
            row(label("Ping"), gap(pingSpin), grow(roleIn, 6)),
            loadstringChk,
            row(picIcon, grow(picBox, 10), gap(thumb), top = 10),
            row(button("Preview") { preview() }, gap(button("Clear") { clear() }), grow(View(this)), postBtn,
                gap(roundIcon("send", 44) { post() }), top = 14))
    }

    private fun currentPost(): Core.Post = Core.Post(titleIn.text.toString(), messageIn.text.toString(), colorSpin.selectedItem as String,
        pingSpin.selectedItem as String, roleIn.text.toString(), loadstringChk.isChecked, nameIn.text.toString(), embedChk.isChecked)

    private fun pickPicture() {
        val i = Intent(Intent.ACTION_GET_CONTENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE)
        @Suppress("DEPRECATION")
        startActivityForResult(Intent.createChooser(i, "Pick a picture"), REQ_PICTURE)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        val uri = data?.data
        if (requestCode == REQ_PICTURE && resultCode == RESULT_OK && uri != null) loadPicture(uri)
    }

    private fun displayName(uri: Uri): String = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: "picture"
    } catch (e: Exception) { "picture" }

    private fun loadPicture(uri: Uri) {
        val name = displayName(uri)
        bg({
            val out = ByteArrayOutputStream()
            contentResolver.openInputStream(uri)?.use { input ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    if (out.size() > Core.MAX_IMAGE) throw Core.PupError("That picture is bigger than 8 MB")
                }
            } ?: throw Core.PupError("That picture could not be opened")
            Core.picture(out.toByteArray(), name)
        }) { pic, err ->
            if (pic == null) { say(err ?: "That picture could not be opened", BAD); return@bg }
            picture = pic
            pictureLbl.text = "$name (${pic.data.size / 1024} KB)"
            pictureLbl.setTextColor(INK)
            removePic.isEnabled = true
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(pic.data, 0, pic.data.size, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= dp(120) || bounds.outHeight / (sample * 2) >= dp(90)) sample *= 2
            thumb.setImageBitmap(BitmapFactory.decodeByteArray(pic.data, 0, pic.data.size, BitmapFactory.Options().apply { inSampleSize = sample }))
        }
    }

    private fun clearPicture() {
        picture = null
        thumb.setImageDrawable(null)
        pictureLbl.text = "No picture (PNG, JPG, GIF or WEBP up to 8 MB)"
        pictureLbl.setTextColor(DIM)
        removePic.isEnabled = false
    }

    private fun handleShare(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        intent.getStringExtra(Intent.EXTRA_TEXT)?.let { if (messageIn.text.isEmpty()) messageIn.setText(it) else messageIn.append("\n" + it) }
        intent.getStringExtra(Intent.EXTRA_SUBJECT)?.let { if (titleIn.text.isEmpty()) titleIn.setText(it) }
        @Suppress("DEPRECATION")
        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        if (uri != null) loadPicture(uri)
        show("compose")
        say("Shared into Pupdates: check it, then post.")
    }

    private fun clear() {
        titleIn.setText("")
        messageIn.setText("")
        template = null
        clearPicture()
    }

    private fun preview() {
        val text = try { Core.previewText(Core.buildPayload(currentPost(), picture?.name), picture) } catch (e: Core.PupError) {
            say(e.message ?: "", BAD); return
        }
        AlertDialog.Builder(this).setTitle("Preview").setMessage(text).setPositiveButton("OK", null).show()
    }

    private fun post() {
        val p = currentPost()
        val relay = store.get("mode") == "relay"
        val url = store.secret("webhook")
        val relayUrl = store.get("relay_url")
        val key = store.secret("relay_key")
        if (relay && (relayUrl.isEmpty() || key.isEmpty())) { say("Enter the relay address and your access key in Settings first.", BAD); return }
        if (!relay && url.isEmpty()) { say("Save your webhook in Settings first.", BAD); return }
        if (p.title.isBlank() && p.message.isBlank() && picture == null) { say("Write a title or a message, or add a picture.", BAD); return }
        val body = try { Core.buildPayload(p, picture?.name) } catch (e: Core.PupError) { say(e.message ?: "", BAD); return }
        val go = {
            store.set("color", p.color); store.set("ping", p.ping); store.set("role_id", p.roleId); store.set("username", p.username)
            store.setBool("embed", p.embed)
            postBtn.isEnabled = false
            say("Posting...")
            val pic = picture
            val tpl = template
            val inf = info
            bg({
                if (relay) Core.postRelay(http, relayUrl, key, Core.relayFields(p), pic).optBoolean("pingDropped")
                else { Core.postWebhook(http, url, body, pic); false }
            }) { dropped, err ->
                postBtn.isEnabled = true
                if (err != null) { say(err, BAD); return@bg }
                if (tpl != null && inf != null) store.set(if (tpl == "script") "last_script_sha" else "last_companion_sha", inf.sha)
                say("Posted to Discord." + if (dropped == true) " The ping was left out: the owner has not allowed you to ping." else "", GOOD)
            }
        }
        if (p.ping != "none") {
            val who = if (p.ping == "role") "the role" else p.ping
            AlertDialog.Builder(this).setMessage("This will ping $who. Post it?")
                .setPositiveButton("Post") { _, _ -> go() }.setNegativeButton("Cancel", null).show()
        } else go()
    }

    // ------------------------------------------------------------------ updates
    private fun buildUpdates(): View {
        latestLbl = label("", dim = true, size = 13f)
        return page(
            label("Fill in an announcement from GitHub: the newest build or version and the changes since your last announcement of it. You can edit it before posting."),
            row(button("Puppy Admin update") { fill("script") }, gap(button("Companion update") { fill("companion") }), top = 12),
            latestLbl)
    }

    private fun fill(which: String) {
        say("Reading the latest build from GitHub...")
        bg({ Core.latest(http) }) { latest, err ->
            if (latest == null) { say(err ?: "", BAD); return@bg }
            info = latest
            latestLbl.text = "Puppy Admin build ${latest.build ?: "?"}, Puppy Companion ${latest.version ?: "?"} (commit ${latest.sha.take(7)})"
            val last = store.get(if (which == "script") "last_script_sha" else "last_companion_sha").ifEmpty { null }
            val (t, m) = if (which == "script") Core.scriptTemplate(latest, last) else Core.companionTemplate(latest, last)
            titleIn.setText(t)
            messageIn.setText(m)
            template = which
            embedChk.isChecked = true
            colorSpin.setSelection(Core.COLORS.keys.indexOf(if (which == "script") "Orange" else "Blue"))
            loadstringChk.isChecked = which == "script"
            show("compose")
            say("Filled in from GitHub. Edit it, then post.")
        }
    }

    // ------------------------------------------------------------------ whitelist
    private fun buildWhitelist(): View {
        wlRelayIn = field("Relay address (https://...workers.dev)").apply { setText(store.get("relay_url")) }
        adminIn = field("Admin key", secret = true)
        adminLbl = label("", dim = true, size = 13f)
        usersBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; background = plate(Color.WHITE, LINE); setPadding(dp(8), dp(4), dp(8), dp(4)) }
        newNameIn = field("Name").apply { inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_WORDS }
        newPingChk = check("may ping", false)
        newKeyLbl = label("", size = 13f).apply { setTextIsSelectable(true); typeface = Typeface.MONOSPACE }
        adminLabel()
        return page(
            label("The relay keeps your webhook secret and lets only the people listed here post, each with their own access key. Set the relay up once (pupdates/relay/README.md)."),
            wlRelayIn,
            row(grow(adminIn), gap(button("Save") { saveAdmin() })),
            adminLbl,
            row(label("On the whitelist", bold = true), grow(View(this)), button("Refresh") { refreshUsers() }, top = 12),
            usersBox,
            row(grow(newNameIn), gap(newPingChk), gap(button("Add", accent = true) { addUser() }), top = 12),
            row(grow(newKeyLbl), gap(button("Copy") { copyKey() })),
            label("A new key is shown once: send it to that person. Adding the same name again gives them a new key.", dim = true, size = 13f))
    }

    private fun adminLabel() {
        adminLbl.text = if (store.secret("admin_key").isNotEmpty()) "An admin key is saved (encrypted)." else "Enter the ADMIN_KEY you gave the relay, then Save."
    }

    private fun admin(): Pair<String, String>? {
        val base = wlRelayIn.text.toString().trim()
        if (base != store.get("relay_url")) { store.set("relay_url", base); relayIn.setText(base) }
        val key = adminIn.text.toString().trim().ifEmpty { store.secret("admin_key") }
        if (!Core.validRelay(base)) { say("Enter the relay address (https://...workers.dev).", BAD); return null }
        if (key.isEmpty()) { say("Enter your admin key first.", BAD); return null }
        return base to key
    }

    private fun saveAdmin() {
        store.setSecret("admin_key", adminIn.text.toString())
        adminIn.setText("")
        adminLabel()
        say("Admin key saved.", GOOD)
    }

    private fun refreshUsers() {
        val (base, key) = admin() ?: return
        bg({ Core.adminList(http, base, key) }) { users, err ->
            if (users == null) { say(err ?: "", BAD); return@bg }
            usersBox.removeAllViews()
            if (users.isEmpty()) usersBox.addView(label("No one yet.", dim = true))
            for (u in users) {
                usersBox.addView(row(grow(label(u.name + if (u.canPing) "   (may ping)" else "")),
                    button("Remove") { removeUser(u.name) }, top = 4))
            }
            say("${users.size} on the whitelist.", GOOD)
        }
    }

    private fun addUser() {
        val (base, key) = admin() ?: return
        val name = newNameIn.text.toString().trim()
        if (name.isEmpty()) { say("Type the person's name first.", BAD); return }
        val ping = newPingChk.isChecked
        bg({ Core.adminAdd(http, base, key, name, ping) }) { res, err ->
            if (res == null) { say(err ?: "", BAD); return@bg }
            newKeyLbl.text = res.optString("key")
            newNameIn.setText("")
            say("${res.optString("name", name)} is whitelisted. Copy their key now: it is not shown again.", GOOD)
            refreshUsers()
        }
    }

    private fun removeUser(name: String) {
        val (base, key) = admin() ?: return
        AlertDialog.Builder(this).setMessage("Remove $name? Their key stops working at once.")
            .setPositiveButton("Remove") { _, _ ->
                bg({ Core.adminRemove(http, base, key, name) }) { _, err ->
                    if (err != null) { say(err, BAD); return@bg }
                    say("$name removed.", GOOD)
                    refreshUsers()
                }
            }.setNegativeButton("Cancel", null).show()
    }

    private fun copyKey() {
        val key = newKeyLbl.text.toString()
        if (key.isEmpty()) return
        (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Pupdates key", key))
        say("Key copied.", GOOD)
    }

    // ------------------------------------------------------------------ settings
    private fun buildSettings(): View {
        val hook = RadioButton(this).apply { id = View.generateViewId(); text = "My webhook"; setTextColor(INK); buttonTintList = ColorStateList.valueOf(ORANGE) }
        val relay = RadioButton(this).apply { id = View.generateViewId(); text = "The relay (whitelisted)"; setTextColor(INK); buttonTintList = ColorStateList.valueOf(ORANGE) }
        modeGroup = RadioGroup(this).apply {
            orientation = RadioGroup.VERTICAL
            addView(hook)
            addView(relay)
            check(if (store.get("mode") == "relay") relay.id else hook.id)
            setOnCheckedChangeListener { _, id ->
                store.set("mode", if (id == relay.id) "relay" else "webhook")
                say(modeText())
            }
        }
        webhookIn = field("Webhook URL", secret = true)
        webhookLbl = label("", dim = true, size = 13f)
        relayIn = field("Relay address (https://...)").apply { setText(store.get("relay_url")) }
        keyIn = field("Access key", secret = true)
        relayLbl = label("", dim = true, size = 13f)
        webhookLabel()
        relayLabel(null)
        return page(
            label("Post through", bold = true), modeGroup,
            label("Webhook (owner)", bold = true, size = 16f).apply { setPadding(0, dp(10), 0, 0) },
            row(grow(webhookIn), gap(button("Save") { saveWebhook() })),
            webhookLbl,
            label("Relay (anyone you whitelisted)", bold = true, size = 16f).apply { setPadding(0, dp(10), 0, 0) },
            relayIn,
            row(grow(keyIn), gap(button("Save") { saveRelay() }), gap(button("Check") { checkRelay() }, 4)),
            relayLbl,
            label("The webhook, keys and admin key are encrypted with this phone's key store and never shown again.", dim = true, size = 13f))
    }

    private fun webhookLabel() {
        webhookLbl.text = if (store.secret("webhook").isNotEmpty()) "A webhook is saved. Paste a new one to replace it (empty + Save removes it)."
                          else "Discord: channel > Edit Channel > Integrations > Webhooks > Copy Webhook URL."
    }

    private fun relayLabel(me: org.json.JSONObject?) {
        relayLbl.text = when {
            me != null -> "Whitelisted as ${me.optString("name")}" + (if (me.optBoolean("canPing")) " (may ping)." else ".")
            store.secret("relay_key").isNotEmpty() -> "An access key is saved."
            else -> "Ask the owner for the relay address and your access key."
        }
    }

    private fun saveWebhook() {
        val url = webhookIn.text.toString().trim()
        if (url.isNotEmpty() && !Core.validWebhook(url)) { say("That is not a Discord webhook URL.", BAD); return }
        store.setSecret("webhook", url)
        webhookIn.setText("")
        webhookLabel()
        say(if (url.isEmpty()) "Webhook removed." else "Webhook saved.", GOOD)
    }

    private fun saveRelay(): Boolean {
        val base = relayIn.text.toString().trim()
        if (base.isNotEmpty() && !Core.validRelay(base)) { say("The relay address must start with https://", BAD); return false }
        store.set("relay_url", base)
        wlRelayIn.setText(base)
        if (keyIn.text.toString().isNotBlank()) { store.setSecret("relay_key", keyIn.text.toString()); keyIn.setText("") }
        relayLabel(null)
        say("Relay saved.", GOOD)
        return true
    }

    private fun checkRelay() {
        if ((keyIn.text.toString().isNotBlank() || relayIn.text.toString().trim() != store.get("relay_url")) && !saveRelay()) return
        val base = store.get("relay_url")
        val key = store.secret("relay_key")
        if (base.isEmpty() || key.isEmpty()) { say("Enter the relay address and your access key first.", BAD); return }
        bg({ Core.relayMe(http, base, key) }) { me, err ->
            if (me == null) { say(err ?: "", BAD); return@bg }
            relayLabel(me)
            say("The relay knows you as ${me.optString("name")}.", GOOD)
        }
    }

    companion object {
        private const val REQ_PICTURE = 7
        private val CARD = 0xFFFBFBFB.toInt()
        private val LINE = 0xFFC8CCD4.toInt()
        private val STRIP = 0xFFE6E7EA.toInt()
        private val INK = 0xFF464646.toInt()
        private val DIM = 0xFF8A8D96.toInt()
        private val ORANGE = 0xFFF59B28.toInt()
        private val ORANGE_DARK = 0xFFD98618.toInt()
        private val GOOD = 0xFF3F9B56.toInt()
        private val BAD = 0xFFD0453A.toInt()
    }
}

