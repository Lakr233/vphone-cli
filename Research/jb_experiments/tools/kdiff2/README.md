# kdiff2 — дифф kernelcache между соседними минорными билдами (23F84 → 23G83)

См. `../../27_kdiff_26_5_2_to_26_6_1.md`. Python только для исследований; в репозитории — как справочник.
Запуск (venv с capstone 5): `/tmp/jbresearch/venv/bin/python`.

    python kfun.py <old.kc> <new.kc> com.apple.kernel 2000 > out.txt   # GONE/NEW функции
    python kfnames.py <old.kc> com.apple.kernel 0xADDR ...              # имена по строкам-якорям
    python fdiff.py <old.kc> <new.kc> com.apple.kernel <old_addr> <new_addr>   # diff одной функции

Адрес функции в другом билде ищется заново по строке (`tools/kdiff.py <kc> "<string>"`); адрес старого билда в новый файл подавать нельзя.
`fdis.py <kc> <kext> <addr>` — дизассемблер одной функции. `necp_probe/` — пробник досягаемости NECP из app sandbox (`build.sh` подписывает профилем `me.strelov.wqprobe`).
