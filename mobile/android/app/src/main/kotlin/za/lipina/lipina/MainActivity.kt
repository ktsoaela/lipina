package za.lipina.lipina

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service requires the activity to extend AudioServiceActivity so the
// background engine and the UI share one Flutter engine.
class MainActivity : AudioServiceActivity()
