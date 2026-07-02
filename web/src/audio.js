// Decode any browser-recorded blob (webm/opus etc.) to the 16 kHz mono
// Float32Array Whisper expects. AudioContext resamples during decode.
export async function blobToPcm(blob) {
  const ctx = new AudioContext({ sampleRate: 16000 })
  try {
    const buf = await ctx.decodeAudioData(await blob.arrayBuffer())
    return buf.getChannelData(0)
  } finally {
    await ctx.close()
  }
}
