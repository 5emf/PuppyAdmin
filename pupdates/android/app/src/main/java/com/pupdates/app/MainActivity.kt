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
import android.os.Build
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

    private val sections = listOf("compose", "bot", "status", "updates", "tags", "games", "pet", "whitelist", "settings")
    private val titles = mapOf("compose" to "Compose", "bot" to "Bot", "status" to "Status", "updates" to "Updates", "tags" to "Tags", "games" to "Games", "pet" to "Pet", "whitelist" to "Whitelist", "settings" to "Settings")
    private val descriptions = mapOf(
        "compose" to "Write any message, add a picture, and post it to your Discord channel.",
        "updates" to "Fill in a Puppy Admin or Puppy Companion update from GitHub.",
        "whitelist" to "Choose who may post through your relay (owner only: needs the admin key).",
        "tags" to "Edit Puppy Admin's shared tags: text, colour, picture and who wears them.",
        "games" to "Puppy Admin's mini games, and Game Boy, Game Boy Advance and Doom with its emulators.",
        "pet" to "Your pet cat: feed it, play with it, put it to bed. It lives on while the app is closed.",
        "bot" to "Your Discord bot: sign in, pick where it posts, edit or delete its posts, change its name and picture.",
        "status" to "Keep your bot online with a status, like \"Listening to Jae but mainly Claude\".",
        "settings" to "Bot, webhook or relay, the bubble over other apps, and updates.")
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
    private lateinit var bubbleChk: CheckBox

    // bot
    private lateinit var whereLbl: TextView
    private lateinit var stopEditBtn: TextView
    private lateinit var botTokenIn: EditText
    private lateinit var botWho: TextView
    private lateinit var guildSpin: Spinner
    private lateinit var channelSpin: Spinner
    private lateinit var publishChk: CheckBox
    private lateinit var postsBox: LinearLayout
    private lateinit var botNameIn: EditText
    private var botGuilds = listOf<org.json.JSONObject>()
    private var botChannels = listOf<DiscordBot.Channel>()
    private var filling = false
    private var editing: org.json.JSONObject? = null
    private lateinit var avatarIn: EditText
    private lateinit var updateBtn: TextView
    private lateinit var updateLbl: TextView

    // tags
    private lateinit var tagTokenIn: EditText
    private lateinit var tagTokenLbl: TextView
    private lateinit var tagsBox: LinearLayout
    private lateinit var tagEditor: LinearLayout
    private lateinit var tName: EditText
    private lateinit var tText: EditText
    private lateinit var tSub: EditText
    private lateinit var tColor: EditText
    private lateinit var tRainbow: CheckBox
    private lateinit var tFont: Spinner
    private lateinit var tSize: EditText
    private lateinit var tBackdrop: CheckBox
    private lateinit var tPfp: Spinner
    private lateinit var tImage: EditText
    private lateinit var tOffset: EditText
    private lateinit var tBdColor: EditText
    private lateinit var tBdAlpha: EditText
    private lateinit var tBdImage: EditText
    private lateinit var tBdImgAlpha: EditText
    private lateinit var tBdRound: CheckBox
    private lateinit var tPfpRound: CheckBox
    private lateinit var tagPreview: TagPreview
    private lateinit var tagPreviewNote: TextView
    private var tagImages: TagImages? = null
    private val previewSoon = Runnable { renderTagPreview() }
    private lateinit var membersBox: LinearLayout
    private lateinit var memberIn: EditText
    private var tagList = mutableListOf<org.json.JSONObject>()
    private var tagSha: String? = null
    private var tagIndex = -1
    private val tagNames = HashMap<String, String>()

    // games
    private lateinit var gamesBox: LinearLayout

    // status
    private lateinit var onlineChk: CheckBox
    private lateinit var activitySpin: Spinner
    private lateinit var activityIn: EditText
    private lateinit var dotSpin: Spinner
    private lateinit var presenceLbl: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = Store(this)
        setContentView(buildUi())
        show("compose")
        say(modeText())
        handleShare(intent)
        if (store.getBool("overlay", false)) startBubble(quiet = true)
        if (store.getBool("bot_online", false) && store.secret("bot_token").isNotEmpty()) BotPresenceService.start(this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == Updater.ACTION_STATUS) { installStatus(intent); return }
        handleShare(intent)
    }

    override fun onDestroy() {
        BotPresenceService.listener = null
        main.removeCallbacksAndMessages(null)
        pool.shutdownNow()
        tagImages?.shutdown()
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

    // an empty View with a wrap-content height takes all the height it is offered (that made the card's
    // header fill the whole card), so a spacer is 1 px tall and only stretches sideways
    private fun spacer(): View = View(this).apply { layoutParams = LinearLayout.LayoutParams(0, 1, 1f) }

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
            "status_normal" -> R.drawable.ic_status_normal; "status_hover" -> R.drawable.ic_status_hover; "status_chosen" -> R.drawable.ic_status_chosen
            "bot_normal" -> R.drawable.ic_bot_normal; "bot_hover" -> R.drawable.ic_bot_hover; "bot_chosen" -> R.drawable.ic_bot_chosen
            "tags_normal" -> R.drawable.ic_tags_normal; "tags_hover" -> R.drawable.ic_tags_hover; "tags_chosen" -> R.drawable.ic_tags_chosen
            "games_normal" -> R.drawable.ic_games_normal; "games_hover" -> R.drawable.ic_games_hover; "games_chosen" -> R.drawable.ic_games_chosen
            "pet_normal" -> R.drawable.ic_pet_normal; "pet_hover" -> R.drawable.ic_pet_hover; "pet_chosen" -> R.drawable.ic_pet_chosen
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
        line.addView(ScrollView(this).apply { isVerticalScrollBarEnabled = false; addView(col) },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT))

        val right = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        line.addView(right, LinearLayout.LayoutParams(cardW, ViewGroup.LayoutParams.MATCH_PARENT))
        val card = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; background = plate(CARD, LINE) }
        right.addView(card, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        val logo = ImageView(this).apply { setImageDrawable(drawable("logo")); layoutParams = LinearLayout.LayoutParams(dp(30), dp(30)) }
        val title = label("PUPDATES", size = 18f, bold = true)
        sectionLbl = label("", dim = true)
        val close = label("×", dim = true, size = 24f).apply { setPadding(dp(10), 0, dp(4), 0); setOnClickListener { finish() } }
        val head = row(logo, gap(title, 8), gap(sectionLbl, 6), spacer(), close, top = 0).apply { setPadding(dp(12), dp(10), dp(12), 0) }
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
        pages["bot"] = buildBot()
        pages["status"] = buildStatus()
        pages["tags"] = buildTags()
        pages["games"] = buildGames()
        pages["pet"] = buildPet()
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
        if (name == "compose") whereLabel()
        if (name == "bot") botShown()
        if (name == "whitelist" && store.secret("admin_key").isNotEmpty() && store.get("relay_url").isNotEmpty() && usersBox.childCount == 0) refreshUsers()
    }

    private fun say(text: String, kind: Int = DIM) {
        status.text = text
        status.setTextColor(kind)
    }

    /** bot / webhook / relay: a saved choice, else webhook for older installs that have one, else bot */
    private fun mode(): String = store.get("mode").ifEmpty { if (store.secret("webhook").isNotEmpty()) "webhook" else "bot" }

    private fun modeText(): String = if (mode() == "bot") {
        when {
            store.secret("bot_token").isEmpty() -> "Bot mode: save your bot's token in Bot."
            store.get("bot_channel").isEmpty() -> "Bot mode: pick a channel in Bot."
            else -> "Posting as your bot in #${store.get("bot_channel_name")}."
        }
    } else if (mode() == "relay") {
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
        whereLbl = label("", dim = true, size = 13f)
        stopEditBtn = button("Stop editing") { stopEditing() }.apply { visibility = View.GONE }
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
            row(grow(whereLbl), gap(stopEditBtn), gap(button("Change") { show(if (mode() == "bot") "bot" else "settings") }), top = 0),
            titleIn, messageIn,
            row(embedChk, gap(label("Colour"), 12), gap(colorSpin)),
            row(label("Name"), grow(nameIn, 6)),
            row(label("Ping"), gap(pingSpin), grow(roleIn, 6)),
            loadstringChk,
            row(picIcon, grow(picBox, 10), gap(thumb), top = 10),
            row(button("Preview") { preview() }, gap(button("Clear") { clear() }), spacer(), postBtn,
                gap(roundIcon("send", 44) { post() }), top = 14))
    }

    private fun currentPost(): Core.Post = Core.Post(titleIn.text.toString(), messageIn.text.toString(), colorSpin.selectedItem as String,
        pingSpin.selectedItem as String, roleIn.text.toString(), loadstringChk.isChecked, nameIn.text.toString(), embedChk.isChecked,
        store.get("avatar_url"))

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
        if (resultCode != RESULT_OK || uri == null) return
        when (requestCode) {
            REQ_PICTURE -> loadPicture(uri)
            REQ_ROM_GB -> importGame(uri, "gb")
            REQ_ROM_GBA -> importGame(uri, "gba")
            REQ_WAD -> importGame(uri, "doom")
            REQ_AVATAR -> setWebhookAvatarFrom(uri)
            REQ_BOT_PICTURE -> setBotPictureFrom(uri)
        }
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
        if (mode() == "bot") { postBot(); return }
        val p = currentPost()
        val relay = mode() == "relay"
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

    // ------------------------------------------------------------------ bot
    private fun botClient() = DiscordBot.Client(http, store.secret("bot_token"))

    private fun recentPosts(): org.json.JSONArray = try { org.json.JSONArray(store.get("recent_posts").ifEmpty { "[]" }) } catch (e: Exception) { org.json.JSONArray() }

    private fun buildBot(): View {
        botTokenIn = field("Bot token", secret = true)
        botWho = label("", dim = true, size = 13f)
        guildSpin = spinner(listOf(store.get("bot_guild_name").ifEmpty { "(press Check)" }), "")
        channelSpin = spinner(listOf(store.get("bot_channel_name").let { if (it.isEmpty()) "(no channel yet)" else "#$it" }), "")
        publishChk = check("In announcement channels, publish to the servers that follow it", store.getBool("bot_publish", true)).apply {
            setOnCheckedChangeListener { _, on -> store.setBool("bot_publish", on) }
        }
        postsBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; background = plate(Color.WHITE, LINE); setPadding(dp(8), dp(4), dp(8), dp(4)) }
        botNameIn = field("Bot name").apply { inputType = InputType.TYPE_CLASS_TEXT }
        guildSpin.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) { if (!filling && pos < botGuilds.size) pickGuild(botGuilds[pos], false) }
            override fun onNothingSelected(p: AdapterView<*>?) {}
        }
        channelSpin.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) { if (!filling && pos < botChannels.size) pickChannel(botChannels[pos]) }
            override fun onNothingSelected(p: AdapterView<*>?) {}
        }
        botLabel(null)
        fillPosts()
        return page(
            row(grow(botTokenIn), gap(button("Save") { saveBotToken() }), gap(button("Check") { checkBot() }, 4)),
            botWho,
            row(button("Invite to a server") { inviteBot() }, gap(button("Developer Portal") {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://discord.com/developers/applications")))
            }), top = 4),
            label("If the invite says \"Integration requires code grant\": Developer Portal > your app > Bot > turn off \"Requires OAuth2 Code Grant\" > Save Changes, then invite again.", dim = true, size = 13f),
            label("Where it posts", bold = true, size = 16f).apply { setPadding(0, dp(10), 0, 0) },
            row(label("Server", size = 13f), gap(grow(guildSpin), 6), gap(button("Refresh") { loadGuilds() })),
            row(label("Channel", size = 13f), grow(channelSpin, 6)),
            publishChk,
            label("Recent posts", bold = true, size = 16f).apply { setPadding(0, dp(10), 0, 0) },
            postsBox,
            label("The bot itself", bold = true, size = 16f).apply { setPadding(0, dp(10), 0, 0) },
            row(grow(botNameIn), gap(button("Rename") { renameBot() })),
            row(button("Set its picture") {
                val i = Intent(Intent.ACTION_GET_CONTENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE)
                @Suppress("DEPRECATION")
                startActivityForResult(Intent.createChooser(i, "The bot's picture"), REQ_BOT_PICTURE)
            }, gap(button("Remove picture") { setBotPicture(null) })),
            label("A bot always posts with its own name and picture. Discord lets a bot change its name about twice an hour.", dim = true, size = 13f))
    }

    // ------------------------------------------------------------------ status (the bot online with an activity)
    private fun buildStatus(): View {
        onlineChk = check("Keep the bot online (also while Pupdates is closed; shows a notification)", store.getBool("bot_online", false))
        activitySpin = spinner(Gateway.TYPES.keys.toList(), store.get("bot_activity_type", "Listening"))
        activityIn = field("What it shows").apply { inputType = InputType.TYPE_CLASS_TEXT; setText(store.get("bot_activity_text", BotPresenceService.DEFAULT_TEXT)) }
        dotSpin = spinner(Gateway.STATUSES, store.get("bot_status", "online"))
        presenceLbl = label(BotPresenceService.state.first, dim = true, size = 13f)
        onlineChk.setOnCheckedChangeListener { _, on -> setBotOnline(on) }
        BotPresenceService.listener = { text, ok -> presenceLbl.text = text; presenceLbl.setTextColor(if (ok) GOOD else DIM) }
        return page(
            label("The bot's status", bold = true, size = 16f),
            onlineChk,
            row(activitySpin, grow(activityIn, 6)),
            row(label("Dot", size = 13f), gap(grow(dotSpin), 6), gap(button("Apply") { applyBotStatus() })),
            presenceLbl,
            label("Everyone sees it on the bot: \"Listening to Jae but mainly Claude\". Bots show one line only (no second line, timer or buttons).", dim = true, size = 13f),
            label("Rich presence on your own profile", bold = true, size = 16f).apply { setPadding(0, dp(10), 0, 0) },
            label("\"Listening to ... / May Your Heart Be / Your Guiding Key\" with a timer and the Join button is set from the Windows Pupdates app " +
                "(Status section): it talks to the Discord desktop app on the PC. Discord's phone app has no way for other apps to set it.", dim = true, size = 13f))
    }

    private fun saveBotStatus() {
        store.set("bot_activity_type", activitySpin.selectedItem?.toString() ?: "Listening")
        store.set("bot_activity_text", activityIn.text.toString().trim())
        store.set("bot_status", dotSpin.selectedItem?.toString() ?: "online")
    }

    private fun setBotOnline(on: Boolean) {
        if (on && store.secret("bot_token").isEmpty()) {
            say("Save your bot's token in Bot first.", BAD)
            onlineChk.isChecked = false
            return
        }
        saveBotStatus()
        store.setBool("bot_online", on)
        if (on) {
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED)
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
            presenceLbl.text = "Connecting..."
            BotPresenceService.start(this)
        } else BotPresenceService.stop(this)
    }

    private fun applyBotStatus() {
        saveBotStatus()
        if (store.getBool("bot_online", false)) BotPresenceService.start(this, update = true)
        else say("Saved. Tick \"Keep the bot online\" to show it.", GOOD)
    }

    private fun botLabel(me: org.json.JSONObject?) {
        botWho.text = when {
            me != null -> "Signed in as ${me.optString("username")} (id ${me.optString("id")})."
            store.secret("bot_token").isNotEmpty() -> "A token is saved (encrypted). Press Check to sign in."
            else -> "Make a bot: Developer Portal > New Application > Bot > Reset Token, paste the token here and Save. Then invite it to your server."
        }
    }

    private fun botShown() {
        if (store.secret("bot_token").isNotEmpty() && botGuilds.isEmpty()) loadGuilds()
    }

    private fun saveBotToken() {
        val t = botTokenIn.text.toString().trim()
        if (t.isNotEmpty() && !DiscordBot.validToken(t)) { say("That is not a bot token (Developer Portal > your app > Bot > Reset Token).", BAD); return }
        store.setSecret("bot_token", t)
        botTokenIn.setText("")
        botGuilds = emptyList(); botChannels = emptyList()
        botLabel(null)
        say(if (t.isEmpty()) "Bot token removed." else "Bot token saved.", GOOD)
        if (t.isNotEmpty()) checkBot()
    }

    private fun checkBot() {
        if (store.secret("bot_token").isEmpty()) { say("Save the bot's token first.", BAD); return }
        val c = botClient()
        bg({ c.me() }) { me, err ->
            if (me == null) { say(err ?: "", BAD); return@bg }
            botLabel(me)
            if (botNameIn.text.isEmpty()) botNameIn.setText(me.optString("username"))
            say("Signed in as ${me.optString("username")}.", GOOD)
            loadGuilds()
        }
    }

    private fun inviteBot() {
        val url = DiscordBot.inviteUrl(DiscordBot.appId(store.secret("bot_token")))
        if (url == null) { say("Save the bot's token first (the invite link is made from it).", BAD); return }
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    }

    private fun setSpinner(sp: Spinner, items: List<String>, select: Int) {
        filling = true
        sp.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_item, ArrayList(items)).also {
            it.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        }
        if (select in items.indices) sp.setSelection(select)
        sp.post { filling = false }
    }

    private fun loadGuilds() {
        if (store.secret("bot_token").isEmpty()) return
        val c = botClient()
        bg({ c.guilds() }) { guilds, err ->
            if (guilds == null) { say(err ?: "", BAD); return@bg }
            botGuilds = guilds
            if (guilds.isEmpty()) { setSpinner(guildSpin, listOf("(not in any server)"), 0); say("The bot is in no server yet: press Invite to a server.", BAD); return@bg }
            val i = guilds.indexOfFirst { it.optString("id") == store.get("bot_guild") }.let { if (it < 0) 0 else it }
            setSpinner(guildSpin, guilds.map { it.optString("name") }, i)
            pickGuild(guilds[i], true)
        }
    }

    private fun channelText(ch: DiscordBot.Channel) = "#" + ch.name + (if (ch.type == DiscordBot.ANNOUNCEMENT) "  (announcements)" else "") +
        (if (ch.category.isNotEmpty()) "  - ${ch.category}" else "")

    private fun pickGuild(g: org.json.JSONObject, keepChannel: Boolean) {
        val keep = keepChannel && g.optString("id") == store.get("bot_guild")
        store.set("bot_guild", g.optString("id")); store.set("bot_guild_name", g.optString("name"))
        val c = botClient()
        bg({ c.channels(g.optString("id")) }) { chans, err ->
            if (chans == null) { say(err ?: "", BAD); return@bg }
            botChannels = chans
            if (chans.isEmpty()) { setSpinner(channelSpin, listOf("(no text channel it can see)"), 0); say("The bot cannot see any text channel in ${g.optString("name")}.", BAD); return@bg }
            var i = if (keep) chans.indexOfFirst { it.id == store.get("bot_channel") } else -1
            if (i < 0) i = 0
            setSpinner(channelSpin, chans.map { channelText(it) }, i)
            if (!keep || chans[i].id != store.get("bot_channel")) pickChannel(chans[i])
        }
    }

    private fun pickChannel(ch: DiscordBot.Channel) {
        store.set("bot_channel", ch.id); store.set("bot_channel_name", ch.name); store.set("bot_channel_type", ch.type.toString())
        say("The bot posts in #${ch.name}.", GOOD)
        whereLabel()
    }

    private fun whereLabel() {
        if (!::whereLbl.isInitialized) return
        val e = editing
        whereLbl.text = when {
            e != null -> "Editing the bot's post in #${e.optString("channel_name")}"
            mode() == "bot" -> store.get("bot_channel_name").let { if (it.isEmpty()) "As your bot: pick a channel" else "As your bot in #$it (${store.get("bot_guild_name")})" }
            mode() == "relay" -> "Through the relay"
            else -> "To your webhook's channel"
        }
        stopEditBtn.visibility = if (e != null) View.VISIBLE else View.GONE
        postBtn.text = if (e != null) "Save changes" else "Post to Discord"
    }

    private fun fillPosts() {
        postsBox.removeAllViews()
        val posts = recentPosts()
        if (posts.length() == 0) postsBox.addView(label("Nothing posted by the bot yet.", dim = true))
        val fmt = java.text.SimpleDateFormat("d MMM HH:mm", java.util.Locale.getDefault())
        for (i in 0 until posts.length()) {
            val p = posts.getJSONObject(i)
            val line = "${fmt.format(java.util.Date(p.optLong("time") * 1000))}  #${p.optString("channel_name")}\n${p.optString("title").ifEmpty { "(no title)" }}"
            postsBox.addView(label(line, size = 13f).apply { setPadding(0, dp(6), 0, dp(2)) })
            postsBox.addView(row(button("Edit") { editPost(p) }, gap(button("Delete") { deletePost(p) }), gap(button("Open") {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(DiscordBot.jumpUrl(p.optString("guild"), p.optString("channel"), p.optString("message")))))
            }), top = 2))
        }
    }

    private fun postBot() {
        val p = currentPost().copy(avatarUrl = "")
        val e = editing
        val channel = e?.optString("channel") ?: store.get("bot_channel")
        if (store.secret("bot_token").isEmpty()) { say("Save your bot's token in Bot first.", BAD); return }
        if (channel.isEmpty()) { say("Pick the channel in Bot first.", BAD); return }
        if (p.title.isBlank() && p.message.isBlank() && picture == null) { say("Write a title or a message, or add a picture.", BAD); return }
        if (e != null && picture != null) { say("A picture cannot be swapped on an existing post: delete it and post again.", BAD); return }
        val body = try { Core.buildPayload(p, picture?.name) } catch (x: Core.PupError) { say(x.message ?: "", BAD); return }
        if (e != null) body.put("allowed_mentions", org.json.JSONObject().put("parse", org.json.JSONArray()))   // an edit never pings again
        val go = {
            store.set("color", p.color); store.set("ping", p.ping); store.set("role_id", p.roleId); store.setBool("embed", p.embed)
            postBtn.isEnabled = false
            say(if (e != null) "Saving the changes..." else "Posting...")
            val c = botClient()
            val pic = picture
            val tpl = template
            val inf = info
            val publish = store.getBool("bot_publish", true) && store.get("bot_channel_type") == DiscordBot.ANNOUNCEMENT.toString()
            val title = (p.title.trim().ifEmpty { p.message.trim() }).take(60)
            val channelName = store.get("bot_channel_name")
            val guild = store.get("bot_guild")
            bg({
                if (e != null) { c.edit(channel, e.optString("message"), body); "edited" }
                else {
                    val msg = c.post(channel, body, pic)
                    val note = if (publish) try { c.publish(channel, msg.optString("id")); " Published to following servers." } catch (x: Core.PupError) { " (Not published: ${x.message})" } else ""
                    val entry = org.json.JSONObject().put("guild", guild).put("channel", channel).put("channel_name", channelName)
                        .put("message", msg.optString("id")).put("title", title).put("time", System.currentTimeMillis() / 1000)
                    store.set("recent_posts", DiscordBot.remember(recentPosts(), entry).toString())
                    "Posted in #$channelName.$note"
                }
            }) { res, err ->
                postBtn.isEnabled = true
                if (res == null) { say(err ?: "", BAD); return@bg }
                if (res == "edited") {
                    val posts = recentPosts()
                    for (i in 0 until posts.length()) if (posts.getJSONObject(i).optString("message") == e!!.optString("message")) posts.getJSONObject(i).put("title", title)
                    store.set("recent_posts", posts.toString())
                    editing = null
                    whereLabel()
                    fillPosts()
                    say("Post updated.", GOOD)
                    return@bg
                }
                if (tpl != null && inf != null) store.set(if (tpl == "script") "last_script_sha" else "last_companion_sha", inf.sha)
                fillPosts()
                say(res, if (res.contains("Not published")) BAD else GOOD)
            }
        }
        if (e == null && p.ping != "none") {
            val who = if (p.ping == "role") "the role" else p.ping
            AlertDialog.Builder(this).setMessage("This will ping $who. Post it?")
                .setPositiveButton("Post") { _, _ -> go() }.setNegativeButton("Cancel", null).show()
        } else go()
    }

    private fun editPost(p: org.json.JSONObject) {
        if (store.secret("bot_token").isEmpty()) { say("Save the bot's token first.", BAD); return }
        val c = botClient()
        bg({ c.message(p.optString("channel"), p.optString("message")) }) { msg, err ->
            if (msg == null) { say(err ?: "", BAD); return@bg }
            clear()
            val embeds = msg.optJSONArray("embeds")
            if (embeds != null && embeds.length() > 0) {
                val e = embeds.getJSONObject(0)
                embedChk.isChecked = true
                titleIn.setText(e.optString("title"))
                messageIn.setText(e.optString("description").let { if (it == "-") "" else it })
                val colour = Core.COLORS.entries.firstOrNull { it.value == e.optInt("color", -1) }?.key ?: "Orange"
                colorSpin.setSelection(Core.COLORS.keys.indexOf(colour))
                val f = e.optJSONArray("fields")
                loadstringChk.isChecked = f != null && (0 until f.length()).any { f.getJSONObject(it).optString("name") == "Loadstring" }
            } else {
                embedChk.isChecked = false
                var lines = msg.optString("content").split("\n")
                if (lines.isNotEmpty() && (lines[0].startsWith("@") || lines[0].startsWith("<@&"))) lines = lines.drop(1)
                if (lines.isNotEmpty() && lines[0].startsWith("**") && lines[0].endsWith("**")) { titleIn.setText(lines[0].trim('*')); lines = lines.drop(1) }
                var text = lines.joinToString("\n")
                if (text.contains("```lua")) { text = text.substringBefore("\n```lua"); loadstringChk.isChecked = true }
                messageIn.setText(text)
            }
            pingSpin.setSelection(0)
            editing = org.json.JSONObject().put("channel", p.optString("channel")).put("message", p.optString("message")).put("channel_name", p.optString("channel_name"))
            show("compose")
            say("Editing the post: change it, then Save changes. (Its picture stays; edits do not ping.)")
        }
    }

    private fun stopEditing() {
        editing = null
        clear()
        whereLabel()
        say("Stopped editing.")
    }

    private fun deletePost(p: org.json.JSONObject) {
        AlertDialog.Builder(this).setMessage("Delete this post from Discord?\n\n${p.optString("title").ifEmpty { "(no title)" }}")
            .setPositiveButton("Delete") { _, _ ->
                val c = botClient()
                bg({ c.delete(p.optString("channel"), p.optString("message")) }) { _, err ->
                    if (err != null && !err.contains("no longer exists")) { say(err, BAD); return@bg }
                    val keep = org.json.JSONArray()
                    val posts = recentPosts()
                    for (i in 0 until posts.length()) if (posts.getJSONObject(i).optString("message") != p.optString("message")) keep.put(posts.getJSONObject(i))
                    store.set("recent_posts", keep.toString())
                    fillPosts()
                    say("Post deleted.", GOOD)
                }
            }.setNegativeButton("Cancel", null).show()
    }

    private fun renameBot() {
        val name = botNameIn.text.toString().trim()
        if (name.length !in 2..32) { say("A bot's name is 2 to 32 characters.", BAD); return }
        val c = botClient()
        bg({ c.setProfile(username = name) }) { me, err ->
            if (me == null) { say(err ?: "", BAD); return@bg }
            botLabel(me)
            say("The bot is now ${me.optString("username", name)}.", GOOD)
        }
    }

    private fun setBotPictureFrom(uri: Uri) {
        bg({
            val data = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: throw Core.PupError("That picture could not be opened")
            Core.picture(data, displayName(uri))
        }) { pic, err -> if (pic == null) say(err ?: "", BAD) else setBotPicture(pic) }
    }

    private fun setBotPicture(pic: Core.Picture?) {
        if (pic != null) try { Core.avatarDataUri(pic) } catch (e: Core.PupError) { say(e.message ?: "", BAD); return }
        if (store.secret("bot_token").isEmpty()) { say("Save the bot's token first.", BAD); return }
        val c = botClient()
        say("Changing the bot's picture...")
        bg({ c.setProfile(avatar = pic, clearAvatar = pic == null) }) { _, err ->
            if (err != null) say(err, BAD) else say(if (pic != null) "The bot's picture was changed." else "The bot's picture was removed.", GOOD)
        }
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
            row(label("On the whitelist", bold = true), spacer(), button("Refresh") { refreshUsers() }, top = 12),
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
        bubbleChk = check("Show the Pupdates bubble over other apps", store.getBool("overlay", false)).apply {
            setOnCheckedChangeListener { _, on -> if (on) startBubble(quiet = false) else stopBubble() }
        }
        updateBtn = button("Check for updates") { checkUpdate() }
        avatarIn = field("Picture for each post (https link)").apply { setText(store.get("avatar_url")) }
        updateLbl = label("Version " + (try { packageManager.getPackageInfo(packageName, 0).versionName } catch (e: Exception) { "?" }), dim = true, size = 13f)
        val botRadio = RadioButton(this).apply { id = View.generateViewId(); text = "My bot"; setTextColor(INK); buttonTintList = ColorStateList.valueOf(ORANGE) }
        val hook = RadioButton(this).apply { id = View.generateViewId(); text = "My webhook"; setTextColor(INK); buttonTintList = ColorStateList.valueOf(ORANGE) }
        val relay = RadioButton(this).apply { id = View.generateViewId(); text = "The relay (whitelisted)"; setTextColor(INK); buttonTintList = ColorStateList.valueOf(ORANGE) }
        modeGroup = RadioGroup(this).apply {
            orientation = RadioGroup.VERTICAL
            addView(botRadio)
            addView(hook)
            addView(relay)
            check(when (mode()) { "relay" -> relay.id; "webhook" -> hook.id; else -> botRadio.id })
            setOnCheckedChangeListener { _, id ->
                store.set("mode", when (id) { relay.id -> "relay"; hook.id -> "webhook"; else -> "bot" })
                whereLabel()
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
            label("Webhook picture", bold = true, size = 16f).apply { setPadding(0, dp(10), 0, 0) },
            row(grow(avatarIn), gap(button("Save") { saveAvatarUrl() })),
            row(button("Set the webhook's own picture") { pickAvatar() }, gap(button("Remove it") { setWebhookAvatar(null) })),
            label("Each post: an https link to an image shown instead of the webhook's picture (empty = the webhook's own). Own picture: a PNG / JPG / GIF saved on the webhook for good (needs your webhook, or the relay's admin key).", dim = true, size = 13f),
            label("Overlay", bold = true, size = 16f).apply { setPadding(0, dp(10), 0, 0) },
            bubbleChk,
            label("A round Pupdates bubble stays over every app: tap it to open Pupdates on top of what you are doing, drag it anywhere, long-press to remove it.", dim = true, size = 13f),
            label("Updates", bold = true, size = 16f).apply { setPadding(0, dp(10), 0, 0) },
            row(updateBtn, gap(grow(updateLbl), 8)),
            label("The webhook, keys, admin key and tag token are encrypted with this phone's key store and never shown again.", dim = true, size = 13f))
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

    // ------------------------------------------------------------------ webhook picture
    private fun saveAvatarUrl() {
        val url = avatarIn.text.toString().trim()
        if (url.isNotEmpty() && !Core.validAvatarUrl(url)) { say("The post picture must be an https:// link to an image.", BAD); return }
        store.set("avatar_url", url)
        say(if (url.isEmpty()) "Posts use the webhook's own picture again." else "Posts now use this picture.", GOOD)
    }

    private fun pickAvatar() {
        val i = Intent(Intent.ACTION_GET_CONTENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE)
        @Suppress("DEPRECATION")
        startActivityForResult(Intent.createChooser(i, "The webhook's picture"), REQ_AVATAR)
    }

    private fun setWebhookAvatarFrom(uri: Uri) {
        bg({
            val data = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: throw Core.PupError("That picture could not be opened")
            Core.picture(data, displayName(uri))
        }) { pic, err -> if (pic == null) say(err ?: "", BAD) else setWebhookAvatar(pic) }
    }

    private fun setWebhookAvatar(pic: Core.Picture?) {
        if (pic != null) try { Core.avatarDataUri(pic) } catch (e: Core.PupError) { say(e.message ?: "", BAD); return }
        val url = store.secret("webhook")
        val base = store.get("relay_url")
        val admin = store.secret("admin_key")
        if (url.isEmpty() && (base.isEmpty() || admin.isEmpty())) { say("Save your webhook first (or the relay address and admin key in Whitelist).", BAD); return }
        say("Changing the webhook's picture...")
        bg({ if (url.isNotEmpty()) Core.setWebhookAvatar(http, url, pic) else Core.adminAvatar(http, base, admin, pic) }) { _, err ->
            if (err != null) say(err, BAD) else say(if (pic != null) "The webhook's picture was changed." else "The webhook's picture was removed.", GOOD)
        }
    }

    // ------------------------------------------------------------------ overlay bubble
    private fun startBubble(quiet: Boolean) {
        if (!android.provider.Settings.canDrawOverlays(this)) {
            if (quiet) return
            say("Allow \"Display over other apps\" for Pupdates, then come back.", DIM)
            @Suppress("DEPRECATION")
            startActivityForResult(Intent(android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")), REQ_OVERLAY)
            return
        }
        store.setBool("overlay", true)
        startForegroundService(Intent(this, OverlayService::class.java))
        if (!quiet) say("The bubble is on: it stays over other apps.", GOOD)
    }

    private fun stopBubble() {
        store.setBool("overlay", false)
        stopService(Intent(this, OverlayService::class.java))
        say("The bubble is off.")
    }

    override fun onResume() {
        super.onResume()
        refreshPet()
        if (::bubbleChk.isInitialized) {
            val on = store.getBool("overlay", false) && android.provider.Settings.canDrawOverlays(this)
            if (bubbleChk.isChecked && !on && android.provider.Settings.canDrawOverlays(this)) startBubble(quiet = true)
            else if (bubbleChk.isChecked && !android.provider.Settings.canDrawOverlays(this)) bubbleChk.isChecked = false
        }
    }

    // ------------------------------------------------------------------ update
    private fun checkUpdate() {
        updateBtn.isEnabled = false
        say("Checking for a Pupdates update...")
        bg({ Updater.check(http) }) { info, err ->
            if (info == null) { updateBtn.isEnabled = true; say(err ?: "", BAD); return@bg }
            val have = Updater.installed(this)
            if (info.versionCode <= have) { updateBtn.isEnabled = true; say("Pupdates is up to date (version ${info.versionName}).", GOOD); return@bg }
            if (!packageManager.canRequestPackageInstalls()) {
                updateBtn.isEnabled = true
                say("Allow Pupdates to install apps (Install unknown apps), then press Check for updates again.", DIM)
                startActivity(Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                return@bg
            }
            AlertDialog.Builder(this).setMessage("Pupdates ${info.versionName} is out. Download and install it?")
                .setPositiveButton("Update") { _, _ -> downloadUpdate(info) }
                .setNegativeButton("Later") { _, _ -> updateBtn.isEnabled = true }.show()
        }
    }

    private fun downloadUpdate(info: Updater.Info) {
        say("Downloading Pupdates ${info.versionName}...")
        bg({
            val f = Updater.download(this, info) { done, total ->
                if (total > 0) main.post { updateLbl.text = "${done * 100 / total}%" }
            }
            Updater.install(this, f)
        }) { _, err ->
            updateBtn.isEnabled = true
            if (err != null) say(err, BAD) else say("Confirm the install in Android's window.")
        }
    }

    private fun installStatus(i: Intent) {
        when (i.getIntExtra(android.content.pm.PackageInstaller.EXTRA_STATUS, -999)) {
            android.content.pm.PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                (i.getParcelableExtra<Intent>(Intent.EXTRA_INTENT))?.let { startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            }
            android.content.pm.PackageInstaller.STATUS_SUCCESS -> say("Updated.", GOOD)
            else -> {
                val msg = i.getStringExtra(android.content.pm.PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "unknown reason"
                say("The update was not installed: $msg" + if (msg.contains("signature", true) || msg.contains("conflict", true))
                    " (the new APK is signed with a different key: uninstall Pupdates once, then install the new one)" else "", BAD)
            }
        }
    }

    // ------------------------------------------------------------------ games
    private fun gameDir(kind: String) = java.io.File(filesDir, when (kind) { "gb" -> "roms/gb"; "gba" -> "roms/gba"; else -> "doom/wads" }).apply { mkdirs() }
    private val freedoom get() = java.io.File(filesDir, "doom/freedoom1.wad")

    private fun buildGames(): View {
        gamesBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        refreshGames()
        return page(
            label("Puppy Admin's own Game Boy and Game Boy Advance emulators, and the Doom engine. Add your own ROMs and WADs: the app ships none, except free Freedoom.", size = 13f),
            gamesBox)
    }

    private fun pick(req: Int) {
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE)
        @Suppress("DEPRECATION")
        startActivityForResult(i, req)
    }

    private fun refreshGames() {
        gamesBox.removeAllViews()
        gamesBox.addView(row(label("Mini games", bold = true, size = 16f), spacer(),
            button("Play", accent = true) { startActivity(Intent(this, MiniGamesActivity::class.java)) }, top = 10))
        gamesBox.addView(label("Snake, Stack Drop, Treat Chase, Star Pup and Puppy Fighter: the same games as Puppy Admin's Games window.", dim = true, size = 13f))
        fun section(title: String, kind: String, req: Int, extra: View? = null) {
            gamesBox.addView(row(label(title, bold = true, size = 16f), spacer(), button(if (kind == "doom") "Add WAD" else "Add ROM") { pick(req) }, top = 14))
            if (extra != null) gamesBox.addView(extra)
            val files = gameDir(kind).listFiles()?.filter { it.isFile }?.sortedBy { it.name.lowercase() } ?: emptyList()
            if (files.isEmpty() && extra == null) gamesBox.addView(label(if (kind == "gba") "No games yet (.gba or .zip)." else "No games yet (.gb or .zip).", dim = true, size = 13f))
            for (f in files) gamesBox.addView(row(grow(label(f.name, size = 14f)), button("Play", accent = true) { play(kind, f) },
                gap(button("×") { deleteGame(f) }, 4), top = 4))
        }
        section("Game Boy", "gb", REQ_ROM_GB)
        section("Game Boy Advance", "gba", REQ_ROM_GBA)
        val free = row(grow(label("Freedoom: Phase 1 (free)" + if (freedoom.isFile) "" else "  - 28 MB download", size = 14f)),
            button("Play", accent = true) { playFreedoom() }, top = 4)
        section("Doom", "doom", REQ_WAD, free)
        gamesBox.addView(label("Doom has sound effects but no music. Game saves are kept in the app.", dim = true, size = 13f).apply { setPadding(0, dp(10), 0, 0) })
    }

    private fun importGame(uri: Uri, kind: String) {
        val name = displayName(uri).replace(Regex("[^\\w .()\\[\\]-]"), "_").take(80).ifEmpty { "game" }
        say("Adding $name...")
        bg({
            val out = java.io.File(gameDir(kind), name)
            contentResolver.openInputStream(uri)?.use { input -> out.outputStream().use { input.copyTo(it) } }
                ?: throw Core.PupError("That file could not be opened")
            if (out.length() > 64L * 1024 * 1024) { out.delete(); throw Core.PupError("That file is bigger than 64 MB") }
            name
        }) { n, err ->
            if (n == null) say(err ?: "", BAD) else { say("$n added.", GOOD); refreshGames() }
        }
    }

    private fun deleteGame(f: java.io.File) {
        AlertDialog.Builder(this).setMessage("Remove ${f.name}? (Its save stays.)")
            .setPositiveButton("Remove") { _, _ -> f.delete(); refreshGames() }.setNegativeButton("Cancel", null).show()
    }

    private fun play(kind: String, f: java.io.File) {
        startActivity(Intent(this, EmuActivity::class.java).putExtra(EmuActivity.EXTRA_KIND, kind).putExtra(EmuActivity.EXTRA_PATH, f.absolutePath))
    }

    private fun playFreedoom() {
        if (freedoom.isFile) { play("doom", freedoom); return }
        say("Downloading Freedoom (28 MB)...")
        bg({
            val part = java.io.File(freedoom.path + ".part").apply { parentFile?.mkdirs() }
            val c = java.net.URL("https://raw.githubusercontent.com/${Core.REPO}/${Core.BRANCH}/assets/doom/freedoom1.wad").openConnection() as java.net.HttpURLConnection
            try {
                if (c.responseCode != 200) throw Core.PupError("GitHub answered HTTP ${c.responseCode}")
                val total = c.contentLengthLong
                var done = 0L
                c.inputStream.use { input -> part.outputStream().use { o ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf); if (n < 0) break
                        o.write(buf, 0, n); done += n
                        if (total > 0) main.post { say("Downloading Freedoom: ${done * 100 / total}%") }
                    }
                } }
            } catch (e: java.io.IOException) { throw Core.PupError("Could not download Freedoom: ${e.message}") } finally { c.disconnect() }
            val head = part.inputStream().use { val b = ByteArray(4); it.read(b); String(b, Charsets.US_ASCII) }
            if (head != "IWAD" || part.length() < 1_000_000) { part.delete(); throw Core.PupError("The Freedoom download is not a WAD") }
            part.renameTo(freedoom)
        }) { _, err ->
            if (err != null) say(err, BAD) else { say("Freedoom is ready.", GOOD); refreshGames(); play("doom", freedoom) }
        }
    }

    // ------------------------------------------------------------------ pet
    private lateinit var pet: Pet
    private lateinit var petView: PetView
    private lateinit var petName: TextView
    private lateinit var petMood: TextView
    private lateinit var petBars: List<Pair<String, View>>
    private lateinit var sleepBtn: TextView
    private val petTick = object : Runnable {
        override fun run() { refreshPet(); main.postDelayed(this, 30_000) }
    }

    private fun bar(): View = View(this).apply { background = plate(GOOD, GOOD) }

    private fun buildPet(): View {
        val now = System.currentTimeMillis()
        pet = Pet.fromJson(store.get("pet"), now)
        pet.advance(now)
        petView = PetView(this) { petDo("pat") }.also { it.pet = pet }
        petName = label(pet.name, bold = true, size = 18f)
        petMood = label("", dim = true, size = 13f)
        petBars = listOf("Food", "Fun", "Energy").map { it to bar() }
        sleepBtn = button("Sleep") { petDo("sleep") }
        val bars = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        for ((name, b) in petBars) {
            val track = FrameLayout(this).apply { background = plate(0xFFE6E7EA.toInt(), LINE) }
            track.addView(b, FrameLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT))
            bars.addView(row(label(name, size = 13f).apply { minWidth = dp(56) }, gap(grow(track), 6), top = 4))
            track.layoutParams = LinearLayout.LayoutParams(0, dp(12), 1f).also { it.leftMargin = dp(6) }
        }
        main.postDelayed(petTick, 30_000)
        val box = page(
            row(petName, gap(petMood, 8), spacer(), button("Rename") { renamePet() }, top = 0),
            petView.also { it.layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(200)).also { lp -> lp.topMargin = dp(6) } },
            bars,
            row(button("Feed", accent = true) { petDo("feed") }, gap(button("Play", accent = true) { petDo("play") }), gap(sleepBtn), top = 12),
            label("Tap the cat to pat it. Food, fun and energy go down over time, also while the app is closed; sleep refills energy.", dim = true, size = 13f))
        refreshPet()
        return box
    }

    private fun refreshPet() {
        if (!::pet.isInitialized) return
        val now = System.currentTimeMillis()
        pet.advance(now)
        petName.text = pet.name
        petMood.text = "${pet.mood()}  \u00b7  Lv ${pet.level}  \u00b7  ${pet.ageDays(now)} days"
        val values = listOf(pet.hunger, pet.joy, pet.energy)
        for ((i, pb) in petBars.withIndex()) {
            val v = values[i]
            val track = pb.second.parent as? View ?: continue
            val w = ((track.width.takeIf { it > 0 } ?: dp(200)) * v / 100.0).toInt()
            pb.second.layoutParams = (pb.second.layoutParams as FrameLayout.LayoutParams).also { it.width = w }
            pb.second.background = plate(if (v < Pet.LOW) BAD else if (v < 50) 0xFFF0CD3C.toInt() else GOOD, 0x00000000)
            pb.second.requestLayout()
        }
        sleepBtn.text = if (pet.asleep) "Wake up" else "Sleep"
        store.set("pet", pet.toJson())
    }

    private fun petDo(what: String) {
        val now = System.currentTimeMillis()
        val answer = when (what) {
            "feed" -> pet.feed(now).also { if (it.isEmpty()) petView.play(Pet.Frames.EAT, 2600) }
            "play" -> pet.play(now).also { if (it.isEmpty()) petView.play(Pet.Frames.HAPPY + Pet.Frames.CAPE + Pet.Frames.HAPPY, 2400) }
            "pat" -> pet.pat(now).also { if (it.isEmpty()) petView.play(Pet.Frames.HAPPY, 900) }
            else -> pet.toggleSleep(now)
        }
        if (answer.isNotEmpty()) { say(answer); if (!pet.asleep) petView.play(Pet.Frames.SAD, 1200) }
        else if (what != "pat") say(when (what) { "feed" -> "Yum!"; "play" -> "${pet.name} had fun!"; else -> if (pet.asleep) "Good night." else "Good morning!" }, GOOD)
        refreshPet()
    }

    private fun renamePet() {
        val input = field("Name").apply { setText(pet.name) }
        AlertDialog.Builder(this).setTitle("Your pet's name").setView(input)
            .setPositiveButton("OK") { _, _ ->
                val n = input.text.toString().trim().take(20)
                if (n.isNotEmpty()) { pet.name = n; refreshPet() }
            }.setNegativeButton("Cancel", null).show()
    }

    // ------------------------------------------------------------------ tags
    private fun buildTags(): View {
        tagTokenIn = field("GitHub token", secret = true)
        tagTokenLbl = label("", dim = true, size = 13f)
        tagsBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; background = plate(Color.WHITE, LINE); setPadding(dp(8), dp(4), dp(8), dp(4)) }
        tName = field("Name (only shown here)")
        tText = field("Text")
        tSub = field("Under it")
        tColor = field("#ffffff").apply { inputType = InputType.TYPE_CLASS_TEXT }
        tRainbow = check("Rainbow", false)
        tFont = spinner(Tags.FONTS, "GothamBold")
        val decimal = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
        tSize = field("22").apply { inputType = decimal }
        tOffset = field("3").apply { inputType = decimal }
        tBackdrop = check("Backdrop", false)
        tPfp = spinner(Tags.PFP_MODES, "none")
        tImage = field("Picture: id, rbxassetid or image URL")
        tPfpRound = check("Round picture", true)
        tBdColor = field("#121216").apply { inputType = InputType.TYPE_CLASS_TEXT }
        tBdRound = check("Rounded corners", true)
        tBdAlpha = field("0.35").apply { inputType = decimal }
        tBdImgAlpha = field("0.15").apply { inputType = decimal }
        tBdImage = field("Backdrop image: id, rbxassetid or URL")
        tagPreview = TagPreview(this)
        val watcher = object : android.text.TextWatcher {
            override fun afterTextChanged(e: android.text.Editable?) = updateTagPreview()
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
        }
        tagPreviewNote = label("", dim = true, size = 12f)
        for (e in listOf(tText, tSub, tColor, tSize, tOffset, tBdColor, tBdAlpha, tBdImgAlpha, tImage, tBdImage)) e.addTextChangedListener(watcher)
        tFont.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) = updateTagPreview()
            override fun onNothingSelected(p: AdapterView<*>?) {}
        }
        for (c in listOf(tRainbow, tBackdrop, tBdRound, tPfpRound)) c.setOnCheckedChangeListener { _, _ -> updateTagPreview() }
        tPfp.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) = updateTagPreview()
            override fun onNothingSelected(p: AdapterView<*>?) {}
        }
        membersBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; background = plate(Color.WHITE, LINE); setPadding(dp(8), dp(4), dp(8), dp(4)) }
        memberIn = field("Roblox username or user id").apply { inputType = InputType.TYPE_CLASS_TEXT }
        tagEditor = page(
            tagPreview.also { it.layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).also { lp -> lp.topMargin = dp(6) } },
            tagPreviewNote,
            row(label("Text", size = 13f), grow(tText, 6)), row(label("Under it", size = 13f), grow(tSub, 6)),
            row(label("Name", size = 13f), grow(tName, 6)),
            row(label("Colour", size = 13f), grow(tColor, 6), gap(tRainbow)),
            row(label("Font", size = 13f), gap(tFont)),
            row(label("Size", size = 13f), grow(tSize, 6), gap(label("Height", size = 13f), 10), grow(tOffset, 6)),
            row(label("Picture", size = 13f), gap(tPfp), gap(tPfpRound)),
            tImage,
            row(tBackdrop, grow(tBdColor, 6), gap(tBdRound), top = 10),
            row(label("See-through", size = 13f), grow(tBdAlpha, 6), gap(label("Image", size = 13f), 10), grow(tBdImgAlpha, 6)),
            tBdImage,
            label("Who wears it", bold = true).apply { setPadding(0, dp(8), 0, 0) },
            membersBox,
            row(grow(memberIn), gap(button("Add") { addMember() })),
            row(button("Delete tag") { deleteTag() }, spacer(), button("Save to GitHub", accent = true) { saveTags() }, top = 12)
        ).apply { setPadding(0, 0, 0, 0); visibility = View.GONE }
        tagTokenLabel()
        return page(
            row(grow(tagTokenIn), gap(button("Save") { saveTagToken() }), gap(button("Load") { loadTags() }, 4)),
            tagTokenLbl,
            row(label("Tags", bold = true), spacer(), button("New tag") { newTag() }, top = 10),
            tagsBox,
            tagEditor)
    }

    private fun tagTokenLabel() {
        tagTokenLbl.text = if (store.secret("tags_token").isNotEmpty()) "A token is saved (encrypted): you can save tag changes."
            else "Anyone can load the tags. Saving needs a fine-grained GitHub token for 5emf/PuppyAdmin with Contents: read and write."
    }

    private fun saveTagToken() {
        store.setSecret("tags_token", tagTokenIn.text.toString())
        tagTokenIn.setText("")
        tagTokenLabel()
        say(if (store.secret("tags_token").isEmpty()) "Token removed." else "Token saved.", GOOD)
    }

    private fun tagTitle(t: org.json.JSONObject) =
        (if (t.opt("isDefault") == true) "(default) " else "") + t.optString("name") + "   [" + Tags.members(t).size + "]"

    private fun fillTags() {
        tagsBox.removeAllViews()
        if (tagList.isEmpty()) tagsBox.addView(label("Press Load.", dim = true))
        for ((i, t) in tagList.withIndex()) {
            tagsBox.addView(label(tagTitle(t)).apply {
                setPadding(dp(6), dp(8), dp(6), dp(8))
                if (i == tagIndex) { setBackgroundColor(ORANGE); setTextColor(Color.WHITE) }
                setOnClickListener { if (storeTag()) showTag(i) }
            })
        }
    }

    private fun loadTags() {
        say("Loading the tags...")
        val token = store.secret("tags_token").ifEmpty { null }
        bg({ Tags.load(http, token) }) { res, err ->
            if (res == null) { say(err ?: "", BAD); return@bg }
            tagList = res.first
            tagSha = res.second
            tagIndex = -1
            fillTags()
            tagEditor.visibility = View.GONE
            say("${tagList.size} tags loaded.", GOOD)
            val ids = tagList.flatMap { Tags.members(it) }.toSet()
            bg({ Tags.userNames(http, ids) }) { names, _ -> if (names != null) { tagNames.putAll(names); showMembers() } }
        }
    }

    private fun storeTag(): Boolean {
        if (tagIndex < 0) return true
        val t = tagList[tagIndex]
        val color: org.json.JSONArray
        val bdColor: org.json.JSONArray
        try {
            color = Tags.parseHex(tColor.text.toString())
            bdColor = Tags.parseHex(tBdColor.text.toString())
        } catch (e: Core.PupError) { say(e.message ?: "", BAD); return false }
        fun num(e: EditText, def: Double): Double? = e.text.toString().trim().let { if (it.isEmpty()) def else it.toDoubleOrNull() }
        val size = num(tSize, 22.0); val offset = num(tOffset, 3.0); val alpha = num(tBdAlpha, 0.35); val imgAlpha = num(tBdImgAlpha, 0.15)
        if (size == null || offset == null || alpha == null || imgAlpha == null) {
            say("Size, height and see-through are numbers (size 8-48, height 0-12, see-through 0-1).", BAD); return false
        }
        t.put("name", tName.text.toString()).put("text", tText.text.toString()).put("sub", tSub.text.toString()).put("color", color)
            .put("rainbow", tRainbow.isChecked).put("font", tFont.selectedItem as String).put("size", size).put("offset", offset)
        t.getJSONObject("backdrop").put("on", tBackdrop.isChecked).put("color", bdColor).put("transparency", alpha)
            .put("image", tBdImage.text.toString().trim()).put("imageTransparency", imgAlpha).put("round", tBdRound.isChecked)
        t.getJSONObject("pfp").put("mode", tPfp.selectedItem as String).put("image", tImage.text.toString().trim()).put("round", tPfpRound.isChecked)
        tagList[tagIndex] = Tags.clean(t)
        return true
    }

    private fun showTag(i: Int) {
        tagIndex = i
        val t = tagList[i]
        tName.setText(t.optString("name")); tText.setText(t.optString("text")); tSub.setText(t.optString("sub"))
        tColor.setText(Tags.hex(t.getJSONArray("color"))); tRainbow.isChecked = t.optBoolean("rainbow")
        tFont.setSelection(Tags.FONTS.indexOf(t.optString("font")).coerceAtLeast(0))
        fun n(d: Double) = if (d == Math.floor(d)) d.toInt().toString() else d.toString()
        val bd = t.getJSONObject("backdrop")
        val pf = t.getJSONObject("pfp")
        tSize.setText(n(t.optDouble("size", 22.0)))
        tOffset.setText(n(t.optDouble("offset", 3.0)))
        tBackdrop.isChecked = bd.optBoolean("on")
        tBdColor.setText(Tags.hex(bd.getJSONArray("color")))
        tBdAlpha.setText(n(bd.optDouble("transparency", 0.35)))
        tBdImage.setText(bd.optString("image"))
        tBdImgAlpha.setText(n(bd.optDouble("imageTransparency", 0.15)))
        tBdRound.isChecked = bd.optBoolean("round", true)
        tPfp.setSelection(Tags.PFP_MODES.indexOf(pf.optString("mode")).coerceAtLeast(0))
        tImage.setText(pf.optString("image"))
        tPfpRound.isChecked = pf.optBoolean("round", true)
        updateTagPreview()
        tagEditor.visibility = View.VISIBLE
        fillTags()
        showMembers()
    }

    /** redraws the preview a moment after the last edit (a link being typed is not fetched letter by letter) */
    private fun updateTagPreview() {
        if (!::tagPreview.isInitialized) return
        main.removeCallbacks(previewSoon)
        main.postDelayed(previewSoon, 350)
    }

    /** the tag as the fields describe it right now (half-typed numbers and colours keep the saved value) */
    private fun tagFromFields(): org.json.JSONObject {
        val t = org.json.JSONObject(tagList[tagIndex].toString())
        fun num(e: EditText, def: Double) = e.text.toString().trim().toDoubleOrNull() ?: def
        fun col(e: EditText, def: org.json.JSONArray) = try { Tags.parseHex(e.text.toString()) } catch (x: Exception) { def }
        t.put("text", tText.text.toString()).put("sub", tSub.text.toString()).put("color", col(tColor, t.getJSONArray("color")))
            .put("rainbow", tRainbow.isChecked).put("font", tFont.selectedItem as String)
            .put("size", num(tSize, t.optDouble("size", 22.0))).put("offset", num(tOffset, t.optDouble("offset", 3.0)))
        val bd = t.getJSONObject("backdrop")
        bd.put("on", tBackdrop.isChecked).put("color", col(tBdColor, bd.getJSONArray("color")))
            .put("transparency", num(tBdAlpha, bd.optDouble("transparency", 0.35))).put("image", tBdImage.text.toString())
            .put("imageTransparency", num(tBdImgAlpha, bd.optDouble("imageTransparency", 0.15))).put("round", tBdRound.isChecked)
        t.getJSONObject("pfp").put("mode", tPfp.selectedItem as String).put("image", tImage.text.toString()).put("round", tPfpRound.isChecked)
        return Tags.clean(t)
    }

    private fun renderTagPreview() {
        if (!::tagPreview.isInitialized) return
        if (tagIndex < 0 || tagIndex >= tagList.size) { tagPreview.show(null, null, null, false); tagPreviewNote.text = ""; return }
        val t = tagFromFields()
        val first = if (t.opt("isDefault") == true) null else Tags.members(t).firstOrNull()
        val plan = TagLook.plan(t, first, first?.let { tagNames[it] })
        val images = tagImages ?: TagImages().also { tagImages = it }
        val pic = images.get(plan.picture) { renderTagPreview() }
        val back = images.get(plan.backdrop) { renderTagPreview() }
        val custom = t.getJSONObject("pfp").optString("mode") == "custom"
        for ((what, item, gone) in listOf(Triple("Picture", pic, if (custom) "so the game shows no picture" else "the game still shows the avatar"),
                                          Triple("Backdrop image", back, "so the game shows the plain backdrop"))) {
            if (item == null) continue
            when (item.state) {
                "loading" -> plan.notes.add("$what: loading...")
                "failed" -> plan.notes.add("$what: could not load (${item.error}), $gone.")
                else -> if (item.note.isNotEmpty()) plan.notes.add("$what: ${item.note}")
            }
        }
        val hasPicture = t.getJSONObject("pfp").optString("mode") == "avatar" || (custom && pic?.state == "ok")
        tagPreview.show(t, if (pic?.state == "ok") pic.bitmap else null, if (back?.state == "ok") back.bitmap else null, hasPicture)
        val off = t.optDouble("offset", 3.0)
        plan.notes.add("Height: ${if (off == Math.floor(off)) off.toInt().toString() else off.toString()} studs above the head (Roblox places it in the world).")
        tagPreviewNote.text = plan.notes.joinToString("\n")
    }

    private fun showMembers() {
        membersBox.removeAllViews()
        if (tagIndex < 0) return
        val t = tagList[tagIndex]
        if (t.opt("isDefault") == true) {
            membersBox.addView(label("The default tag: worn by everyone running Puppy Admin with no other tag.", dim = true, size = 13f))
            return
        }
        val ids = Tags.members(t)
        if (ids.isEmpty()) membersBox.addView(label("No one yet.", dim = true))
        for (id in ids) membersBox.addView(row(grow(label(tagNames[id]?.let { "$it ($id)" } ?: id)), button("×") {
            Tags.setMembers(t, Tags.members(t) - id); fillTags(); showMembers(); say("Removed (not saved yet).")
        }, top = 4))
    }

    private fun newTag() {
        if (!storeTag()) return
        if (tagSha == null && tagList.isEmpty()) { say("Load the tags first.", BAD); return }
        if (tagList.size >= Tags.MAX_TAGS) { say("Puppy Admin keeps at most ${Tags.MAX_TAGS} tags.", BAD); return }
        tagList.add(Tags.newTag())
        showTag(tagList.size - 1)
        say("New tag added: fill it in, add who wears it, then Save to GitHub.")
    }

    private fun deleteTag() {
        if (tagIndex < 0) return
        val name = tagList[tagIndex].optString("name")
        AlertDialog.Builder(this).setMessage("Delete the tag $name?").setPositiveButton("Delete") { _, _ ->
            tagList.removeAt(tagIndex); tagIndex = -1; tagEditor.visibility = View.GONE; fillTags(); say("$name deleted (not saved yet).")
        }.setNegativeButton("Cancel", null).show()
    }

    private fun addMember() {
        if (tagIndex < 0 || tagList[tagIndex].opt("isDefault") == true) { say("Pick a tag (not the default one) first.", BAD); return }
        val text = memberIn.text.toString()
        val index = tagIndex
        bg({ Tags.userId(http, text) }) { res, err ->
            if (res == null) { say(err ?: "", BAD); return@bg }
            val (id, name) = res
            val target = tagList[index]
            val other = Tags.ownerOf(tagList, id)
            val add = {
                other?.let { Tags.setMembers(it, Tags.members(it) - id) }
                Tags.setMembers(target, Tags.members(target) + id)
                if (name != null) tagNames[id] = name
                memberIn.setText("")
                fillTags(); showMembers()
                say("${name ?: id} added (not saved yet).", GOOD)
            }
            when {
                other === target -> say("They already wear this tag.")
                other != null -> AlertDialog.Builder(this).setMessage("${name ?: id} already wears ${other.optString("name")}. Move them to this tag?")
                    .setPositiveButton("Move") { _, _ -> add() }.setNegativeButton("Cancel", null).show()
                else -> add()
            }
        }
    }

    private fun saveTags() {
        if (!storeTag()) return
        val token = store.secret("tags_token")
        if (token.isEmpty()) { say("Save your GitHub token first (it needs Contents: read and write).", BAD); return }
        val snapshot = tagList.map { org.json.JSONObject(it.toString()) }
        say("Saving the tags to GitHub...")
        bg({ Tags.save(http, snapshot, tagSha, token) }) { sha, err ->
            if (err != null) { say(err, BAD); return@bg }
            tagSha = sha
            say("Saved: Puppy Admin picks the new tags up within a minute or two.", GOOD)
        }
    }

    companion object {
        private const val REQ_PICTURE = 7
        private const val REQ_ROM_GB = 8
        private const val REQ_ROM_GBA = 9
        private const val REQ_WAD = 10
        private const val REQ_OVERLAY = 11
        private const val REQ_AVATAR = 12
        private const val REQ_BOT_PICTURE = 13
        private const val REQ_NOTIFY = 14
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

