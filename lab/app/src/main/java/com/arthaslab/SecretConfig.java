package com.arthaslab;

import org.springframework.stereotype.Component;

/**
 * 演示 getstatic：硬编码静态凭据 / 运行时开关。
 * 静态扫描可能漏（被配置覆盖、被反射改），运行时 getstatic 一读即真相。
 *   getstatic com.arthaslab.SecretConfig SECRET_TOKEN
 *   getstatic com.arthaslab.SecretConfig DEBUG_MODE
 */
@Component
public class SecretConfig {
    public static final String SECRET_TOKEN = "AKIA-TEST-DEADBEEF-2026";
    public static boolean DEBUG_MODE = false;
}
