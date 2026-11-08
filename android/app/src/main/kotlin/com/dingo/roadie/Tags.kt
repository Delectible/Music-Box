package com.dingo.roadie

import org.jaudiotagger.audio.AudioFileIO
import org.jaudiotagger.tag.FieldKey
import org.jaudiotagger.tag.TagOptionSingleton
import org.jaudiotagger.tag.images.ArtworkFactory
import java.io.File
import java.util.logging.Level
import java.util.logging.Logger

/** Reads and writes the tags inside a music file (MP3, FLAC, M4A, OGG...). */
object Tags {
    init {
        TagOptionSingleton.getInstance().isAndroid = true
        Logger.getLogger("org.jaudiotagger").level = Level.OFF
    }

    private val fields = mapOf(
        "title" to FieldKey.TITLE,
        "artist" to FieldKey.ARTIST,
        "album" to FieldKey.ALBUM,
        "albumArtist" to FieldKey.ALBUM_ARTIST,
        "genre" to FieldKey.GENRE,
        "year" to FieldKey.YEAR,
        "track" to FieldKey.TRACK,
        "trackTotal" to FieldKey.TRACK_TOTAL,
        "disc" to FieldKey.DISC_NO,
        "discTotal" to FieldKey.DISC_TOTAL,
        "musicbrainzTrackId" to FieldKey.MUSICBRAINZ_TRACK_ID,
        "musicbrainzReleaseId" to FieldKey.MUSICBRAINZ_RELEASEID,
        "musicbrainzArtistId" to FieldKey.MUSICBRAINZ_ARTISTID,
        "comment" to FieldKey.COMMENT,
    )

    fun read(path: String): Map<String, Any?> {
        val f = AudioFileIO.read(File(path))
        val tag = f.tag
        val out = HashMap<String, Any?>()
        if (tag != null) {
            for ((k, key) in fields) {
                val v = try { tag.getFirst(key) } catch (_: Exception) { "" }
                if (!v.isNullOrBlank()) out[k] = v
            }
            out["hasCover"] = tag.firstArtwork != null
        } else {
            out["hasCover"] = false
        }
        val h = f.audioHeader
        out["durationMs"] = h.trackLength * 1000L
        out["format"] = h.format
        out["encoding"] = h.encodingType
        out["bitRate"] = h.bitRate
        out["sampleRate"] = h.sampleRate
        out["bitsPerSample"] = h.bitsPerSample
        out["lossless"] = h.isLossless
        out["variableBitRate"] = h.isVariableBitRate
        return out
    }

    /** Everything about the audio and tags, for the song info screen. */
    fun details(path: String): Map<String, Any?> {
        val f = AudioFileIO.read(File(path))
        val h = f.audioHeader
        val out = LinkedHashMap<String, Any?>()
        out["format"] = h.format
        out["encoding"] = h.encodingType
        out["bitRate"] = h.bitRate
        out["variableBitRate"] = h.isVariableBitRate
        out["sampleRate"] = h.sampleRate
        out["channels"] = h.channels
        out["bitsPerSample"] = h.bitsPerSample
        out["lossless"] = h.isLossless
        out["durationMs"] = (h.preciseTrackLength * 1000).toLong()
        val tag = f.tag
        if (tag != null) {
            out["tagType"] = tag.javaClass.simpleName.removeSuffix("Tag").ifEmpty { "Tag" }
            val fields = ArrayList<List<String>>()
            for (field in tag.fields) {
                if (field.isBinary) continue
                val v = field.toString().trim()
                if (v.isNotEmpty()) fields += listOf(field.id, v.take(400))
            }
            out["fields"] = fields
            val art = tag.firstArtwork
            if (art != null) {
                val bytes = art.binaryData
                out["coverMime"] = art.mimeType
                out["coverBytes"] = bytes?.size ?: 0
                if (bytes != null) {
                    val o = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, o)
                    out["coverWidth"] = o.outWidth
                    out["coverHeight"] = o.outHeight
                }
                out["coverCount"] = tag.artworkList.size
            }
        }
        return out
    }

    /** Sets the given fields (blank values clear them) and, with [cover], the front cover. */
    fun write(path: String, values: Map<String, Any?>, cover: String?) {
        val f = AudioFileIO.read(File(path))
        val tag = f.tagOrCreateAndSetDefault
        for ((k, v) in values) {
            val key = fields[k] ?: continue
            val s = v?.toString()?.trim() ?: ""
            try {
                if (s.isEmpty()) tag.deleteField(key) else tag.setField(key, s)
            } catch (_: Exception) {
                // Some formats don't take every field (e.g. a total on old ID3).
            }
        }
        if (cover != null && File(cover).exists()) {
            val art = ArtworkFactory.getNew()
            art.binaryData = File(cover).readBytes()
            art.mimeType = if (cover.endsWith(".png")) "image/png" else "image/jpeg"
            art.pictureType = 3 // front cover
            tag.deleteArtworkField()
            tag.setField(art)
        }
        f.commit()
    }
}
