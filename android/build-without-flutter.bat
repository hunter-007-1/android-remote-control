@echo off
chcp 65001 >nul
echo ========================================
echo 注意：此脚本需要 Flutter SDK 才能构建
echo ========================================
echo.
echo 请使用以下方法之一：
echo.
echo 方法 1：使用 Android Studio（推荐）
echo   1. 打开 Android Studio
echo   2. File -^> Open -^> 选择项目目录
echo   3. Build -^> Build Bundle(s) / APK(s) -^> Build APK(s)
echo.
echo 方法 2：配置 Flutter SDK 后使用命令行
echo   1. 编辑 android/local.properties
echo   2. 添加：flutter.sdk=C\:\\你的Flutter路径\\flutter
echo   3. 运行：flutter build apk --debug
echo.
pause

