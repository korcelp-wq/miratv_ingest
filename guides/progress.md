# Upgrade Progress

  ### ✅ Generate Upgrade Plan [View Log](logs\1.generatePlan.log)

  ### ❗ Setup Development Environment [View Log](logs\2.setupEnvironment.log)
  
  
  > There are uncommitted changes in the project before upgrading, which have been stashed according to user setting "appModernization.uncommittedChangesAction".
  <details>
      <summary>[ click to toggle details ]</summary>
  
  #### Errors
  - Project compile failed with 1 errors. The project must be compileable before upgrading it, please fix the errors first and then invoke tool #setup\_upgrade\_environment again to setup development environment: - Task 'compileJava' is ambiguous in root project 'MiraTV\\_project\\_PHASES\\_1\\_8' and its subprojects. Candidates are: 'compileDebugAndroidTestJavaWithJavac', 'compileDebugJavaWithJavac', 'compileDebugUnitTestJavaWithJavac', 'compileReleaseJavaWithJavac', 'compileReleaseUnitTestJavaWithJavac'.   \`\`\`   FAILURE: Build failed with an exception.      \\* What went wrong:   Task 'compileJava' is ambiguous in root project 'MiraTV\\_project\\_PHASES\\_1\\_8' and its subprojects. Candidates are: 'compileDebugAndroidTestJavaWithJavac', 'compileDebugJavaWithJavac', 'compileDebugUnitTestJavaWithJavac', 'compileReleaseJavaWithJavac', 'compileReleaseUnitTestJavaWithJavac'.      \\* Try:   \\> Run gradlew tasks to get a list of available tasks.   \\> For more on name expansion, please refer to https://docs.gradle.org/9.0-milestone-1/userguide/command\\_line\\_interface.html#sec:name\\_abbreviation in the Gradle documentation.   \\> Run with --stacktrace option to get the stack trace.   \\> Run with --info or --debug option to get more log output.   \\> Run with --scan to get full insights.   \\> Get more help at https://help.gradle.org.      BUILD FAILED in 29s   \`\`\`
  
  
  - ###
    ### ✅ Install JDK 21
  </details>

  ### ✅ PreCheck [View Log](logs\3.precheck.log)
  
  <details>
      <summary>[ click to toggle details ]</summary>
  
  - ###
    ### ❗ Precheck - Build project [View Log](logs\3.1.precheck-buildProject.log)
    
    <details>
        <summary>[ click to toggle details ]</summary>
    
    #### Command
    `gradlew clean compileJava compileTestJava --continue --parallel --quiet --no-daemon`
    
    #### Errors
    - Task 'compileJava' is ambiguous in root project 'MiraTV\_project\_PHASES\_1\_8' and its subprojects. Candidates are: 'compileDebugAndroidTestJavaWithJavac', 'compileDebugJavaWithJavac', 'compileDebugUnitTestJavaWithJavac', 'compileReleaseJavaWithJavac', 'compileReleaseUnitTestJavaWithJavac'.
      ```
      FAILURE: Build failed with an exception.
      
      \* What went wrong:
      Task 'compileJava' is ambiguous in root project 'MiraTV\_project\_PHASES\_1\_8' and its subprojects. Candidates are: 'compileDebugAndroidTestJavaWithJavac', 'compileDebugJavaWithJavac', 'compileDebugUnitTestJavaWithJavac', 'compileReleaseJavaWithJavac', 'compileReleaseUnitTestJavaWithJavac'.
      
      \* Try:
      \> Run gradlew tasks to get a list of available tasks.
      \> For more on name expansion, please refer to https://docs.gradle.org/9.0-milestone-1/userguide/command\_line\_interface.html#sec:name\_abbreviation in the Gradle documentation.
      \> Run with --stacktrace option to get the stack trace.
      \> Run with --info or --debug option to get more log output.
      \> Run with --scan to get full insights.
      \> Get more help at https://help.gradle.org.
      
      BUILD FAILED in 29s
      ```
    </details>
  </details>

  ### ❗ Setup Development Environment [View Log](logs\4.setupEnvironment.log)
  
  <details>
      <summary>[ click to toggle details ]</summary>
  
  #### Errors
  - Your project is already at the upgrade target you set. Please confirm the upgrade goal first or set a new upgrade goal.
  </details>