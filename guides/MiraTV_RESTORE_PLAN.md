# MiraTV — Working Memory Restore (from MiraTV_project_PHASES_1_8.zip)

## What we have
- **Files in ZIP:** 43
- **Top folders:** {
  "settings.gradle.kts": 1,
  "build.gradle": 1,
  "gradle.properties": 1,
  "README.md": 1,
  "MIGRATION_PLAN.md": 1,
  "BUILD_NOTES.md": 1,
  "app": 37
}
- **Gradle files:** 4
- **AndroidManifest.xml files:** 1
- **Resource directories (res):** 1
- **App module directories named 'app':** 1
- **App-like modules (src/main/java|kotlin + res):**
  app

## Immediate Issues Detected
- **Multiple Gradle roots:** False  
  Paths: .
- **Gradle wrapper present:** False
- **References to @drawable/miratv_logo:** 0  
  Actual asset present: False
- **References to @color/chip_bg:** 0  
  Defined in values: False 

## Minimal Fix Pack (no rework, no feature loss)
1. **Normalize project root**
   - Choose **one** root containing `settings.gradle(.kts)` and move all modules under it.
   - Remove or archive extra Gradle roots to `/archive/` to avoid Android Studio confusion.

2. **Ensure Gradle wrapper + versions**
   - Include `/gradle/wrapper/gradle-wrapper.properties` and `gradlew` scripts.
   - Target stable combo:
     - **Gradle:** 8.7–8.10
     - **AGP:** 8.4–8.7 (match to Gradle)
     - **Kotlin:** 1.9.x or 2.0.x matching AGP

3. **Resource parity**
   - Add `app/src/main/res/drawable/miratv_logo.(png|xml)` to satisfy all `@drawable/miratv_logo` references.
   - Add `app/src/main/res/values/colors.xml` with:
     ```xml
     <resources>
       <color name="chip_bg">#FFE0E0E0</color>
     </resources>
     ```
     (Use your brand color as needed.)

4. **Module consolidation**
   - Keep a single **:app** module with:
     - `src/main/AndroidManifest.xml`
     - `src/main/java/...` (or `kotlin`)
     - `src/main/res/...`

5. **Networking deps**
   - In root/build, ensure:
     - `okhttp`, `retrofit`, `gson` (or moshi)
     - `coroutines`, `lifecycle`, `media3` if using ExoPlayer successor

6. **CI sanity**
   - `./gradlew help` runs clean on import.
   - `./gradlew :app:assembleDebug` produces APK.

## Next Actions I can run immediately
- Produce a **cleaned ZIP** with one Gradle root and one :app module.
- Auto-insert missing `chip_bg` and a placeholder `miratv_logo.png`.
- Align Gradle/AGP/Kotlin versions for a clean build on Android Studio Giraffe+.

