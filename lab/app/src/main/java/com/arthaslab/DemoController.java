package com.arthaslab;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 触发端点：curl 这些 URL 让 watch/trace 命中。
 *   /hello?name=X  — 简单回显
 *   /leak          — 泄露静态凭据（配合 getstatic）
 *   /order?item=X  — 触发 OrderService 链（配合 watch/trace/stack）
 */
@RestController
public class DemoController {

    private final OrderService orderService;

    public DemoController(OrderService orderService) {
        this.orderService = orderService;
    }

    @GetMapping("/hello")
    public String hello(@RequestParam(defaultValue = "world") String name) {
        return "hello, " + name;
    }

    @GetMapping("/leak")
    public String leak() {
        return "token=" + SecretConfig.SECRET_TOKEN;
    }

    @GetMapping("/order")
    public String order(@RequestParam String item) {
        return orderService.createOrder(item);
    }
}
