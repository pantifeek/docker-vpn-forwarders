# Contributing

Перед Pull Request:

```bash
./scripts/check-public-tree.sh
./scripts/check-portainer-templates.sh
```

Не используйте реальные параметры клиентов в tests/examples/issues/logs. Для примеров используйте `example.com`, `corp.local` и документационные/фиктивные адреса.

При изменении VPN wrapper сохраняйте общую модель:

1. tunnel/session health;
2. route-to-target через VPN, где это технически проверяемо;
3. target TCP health;
4. `socat` PID/listener supervision;
5. forwarder-only recovery без VPN reconnect;
6. bounded full recovery с exit PID 1 после серии неудач.

Protocol-specific код может оставаться отдельным: не выносите всё в общую библиотеку ценой усложнения сборки каждого image.
