@echo off
chcp 65001 >nul

set BUILD_TYPE=debug
if not "%1"=="" set BUILD_TYPE=%1

set TIMESTAMP=%DATE:~0,4%%DATE:~5,2%%DATE:~8,2%-%TIME:~0,2%%TIME:~3,2%
set TIMESTAMP=%TIMESTAMP: =0%

echo ================================
echo  BiliMerge APK 构建
echo  类型: %BUILD_TYPE%
echo  时间: %TIMESTAMP%
echo ================================
echo.

call flutter build apk --%BUILD_TYPE%
if %ERRORLEVEL% neq 0 (
    echo.
    echo ❌ 构建失败
    pause
    exit /b %ERRORLEVEL%
)

set OUTPUT_DIR=build\app\outputs\flutter-apk
set SOURCE_APK=%OUTPUT_DIR%\app-%BUILD_TYPE%.apk
set TARGET_APK=%OUTPUT_DIR%\bilimerge-%BUILD_TYPE%-%TIMESTAMP%.apk

if exist "%SOURCE_APK%" (
    copy /Y "%SOURCE_APK%" "%TARGET_APK%" >nul
    echo.
    echo ✅ 构建完成！
    echo    %TARGET_APK%
)

pause
