package com.arthaslab;

import org.springframework.stereotype.Service;

/**
 * 演示 watch / trace / stack：createOrder 接用户输入 → sanitize → saveOrder(sink)。
 *   watch com.arthaslab.OrderService createOrder '{params,returnObj}' -x 2
 *   watch com.arthaslab.OrderService saveOrder '{params,returnObj}' -x 2
 *   trace com.arthaslab.OrderService createOrder
 *   stack com.arthaslab.OrderService saveOrder
 */
@Service
public class OrderService {

    public String createOrder(String item) {
        String normalized = sanitize(item);
        return saveOrder(normalized);
    }

    String sanitize(String input) {
        return input == null ? "unknown" : input.trim().toLowerCase();
    }

    /** sink：模拟落库 / 外调。watch 此处确认污点是否真到 sink。 */
    String saveOrder(String item) {
        return "ORDER-" + item.hashCode() + "-" + (System.currentTimeMillis() % 10000);
    }
}
