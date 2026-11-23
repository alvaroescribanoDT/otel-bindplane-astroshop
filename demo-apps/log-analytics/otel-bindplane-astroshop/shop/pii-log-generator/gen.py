#!/usr/bin/env python3
"""Synthetic order logs with fake PII for the Bindplane redaction demo.

The Astronomy Shop never writes card numbers or emails into logs (only into span attributes), so there is nothing
for lab-redact-pii / lab-redact-cvv to show on logs. This generator emits representative checkout and payment
log lines as OTLP/HTTP JSON to the Bindplane agent on this host, so they travel through the real processors.

Everything is fake: test card numbers, example.com addresses. Every record carries lab.synthetic=true so it can
be filtered out in one query. Standard library only.

  gen.py            send forever (default ~4 orders/min)
  gen.py --dry-run  print one order's payload and exit
"""
import json, os, random, sys, time, urllib.request, uuid

ENDPOINT = os.environ.get("OTLP_LOGS_URL", "http://localhost:4318/v1/logs")
ORDERS_PER_MIN = float(os.environ.get("ORDERS_PER_MIN", "4"))
NAMESPACE = os.environ.get("SERVICE_NAMESPACE", "opentelemetry-demo")

# Small pools so the same hashed values recur across orders: a few customers buying repeatedly is a visible pattern.
CARDS = ["4111111111111111", "5555555555554444", "4012888888881881", "5105105105105100", "4242424242424242", "5200828282828210"]
CARD_WEIGHTS = [30, 25, 18, 12, 10, 5]
EMAILS = ["ana.garcia@example.com", "luis.martin@example.com", "marta.ruiz@example.com", "john.smith@example.com",
          "emma.jones@example.com", "carlos.lopez@example.com", "sofia.diaz@example.com", "paul.miller@example.com"]
EMAIL_WEIGHTS = [26, 20, 16, 12, 10, 8, 5, 3]


def attr(k, v):
    return {"key": k, "value": {"stringValue": str(v)}}


def kv(k, v):
    return {"key": k, "value": {"stringValue": str(v)}}


def record(now_ns, sev, msg, fields, trace_id, span_id):
    pii = [kv(k, fields[k]) for k in ("demo.payment.card_number", "demo.payment.card_cvv", "user.email") if k in fields]
    body = [kv("message", msg)] + [kv(k, v) for k, v in fields.items()]
    return {
        "timeUnixNano": str(now_ns), "observedTimeUnixNano": str(now_ns),
        "severityNumber": {"INFO": 9, "WARN": 13, "ERROR": 17}[sev], "severityText": sev,
        "traceId": trace_id, "spanId": span_id,
        "body": {"kvlistValue": {"values": body}},
        # same keys as on the real checkout/payment spans, so one rule set covers both
        "attributes": pii + [attr("lab.synthetic", "true")],
    }


def resource(service, scope_records, scope):
    return {"resource": {"attributes": [attr("service.name", service), attr("service.namespace", NAMESPACE),
                                        attr("lab.synthetic", "true")]},
            "scopeLogs": [{"scope": {"name": scope}, "logRecords": scope_records}]}


def one_order():
    now = time.time_ns()
    trace_id, order_id = uuid.uuid4().hex, str(uuid.uuid4())
    card = random.choices(CARDS, CARD_WEIGHTS)[0]
    email = random.choices(EMAILS, EMAIL_WEIGHTS)[0]
    amount = round(random.choice([19.99, 34.5, 79.0, 129.95, 249.0, 480.0]) * random.randint(1, 3), 2)
    pii = {"demo.payment.card_number": card, "demo.payment.card_cvv": f"{random.randint(100, 999)}", "user.email": email}
    roll = random.random()
    declined, failed = roll < 0.07, 0.07 <= roll < 0.10

    chk_span, pay_span = uuid.uuid4().hex[:16], uuid.uuid4().hex[:16]
    checkout = [record(now, "INFO", "[PlaceOrder] order received",
                       {"order.id": order_id, "order.items": random.randint(1, 4), **pii}, trace_id, chk_span)]
    payment = [record(now + 40_000_000, "INFO", "Charge request received.",
                      {"order.id": order_id, "order.amount": amount, "order.currency": "USD", **pii}, trace_id, pay_span)]
    if declined:
        payment.append(record(now + 90_000_000, "WARN", "Card declined, customer asked to retry",
                              {"order.id": order_id, "demo.payment.card_number": card, "user.email": email}, trace_id, pay_span))
        checkout.append(record(now + 120_000_000, "WARN", "[PlaceOrder] payment declined",
                               {"order.id": order_id, "user.email": email}, trace_id, chk_span))
    elif failed:
        payment.append(record(now + 90_000_000, "ERROR", "Payment gateway timeout",
                              {"order.id": order_id, "demo.payment.card_number": card}, trace_id, pay_span))
        checkout.append(record(now + 120_000_000, "ERROR", "[PlaceOrder] payment failed",
                               {"order.id": order_id, "user.email": email}, trace_id, chk_span))
    else:
        payment.append(record(now + 90_000_000, "INFO", "Transaction complete.",
                              {"order.id": order_id, "demo.payment.card_number": card}, trace_id, pay_span))
        checkout.append(record(now + 120_000_000, "INFO", "[PlaceOrder] payment went through",
                               {"order.id": order_id, "user.email": email}, trace_id, chk_span))
    return {"resourceLogs": [resource("checkout", checkout, "checkout"), resource("payment", payment, "payment")]}


def send(payload):
    req = urllib.request.Request(ENDPOINT, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status


if __name__ == "__main__":
    if "--dry-run" in sys.argv:
        print(json.dumps(one_order(), indent=1))
        sys.exit(0)
    mean_gap = 60.0 / ORDERS_PER_MIN
    sent = 0
    while True:
        try:
            send(one_order())
            sent += 1
            if sent % 50 == 1:
                print(f"orders sent: {sent}", flush=True)
        except Exception as e:  # agent restarting during a rollout, etc.: keep going
            print(f"send failed: {e}", flush=True)
            time.sleep(5)
        time.sleep(random.expovariate(1.0 / mean_gap))  # Poisson-like arrivals, not a metronome
