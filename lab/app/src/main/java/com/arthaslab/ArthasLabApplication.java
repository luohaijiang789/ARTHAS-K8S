package com.arthaslab;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Arthas-K8s 测试靶机：最小 Spring Boot 3.2 / Java 17 应用。
 * 给 arthas 的 jad/sc/watch/trace/stack/getstatic 提供真实目标。
 */
@SpringBootApplication
public class ArthasLabApplication {
    public static void main(String[] args) {
        SpringApplication.run(ArthasLabApplication.class, args);
    }
}
