"""US federal holidays, computed (no third-party dependency).

Observed rules: a Saturday holiday is observed the preceding Friday, a Sunday
holiday the following Monday. Business-day transit counts Mon-Fri excluding
these observed dates.
"""

import datetime as dt


def _nth_weekday(year, month, weekday, n):
    """n-th `weekday` (Mon=0) of month; n=-1 means last."""
    if n > 0:
        d = dt.date(year, month, 1)
        offset = (weekday - d.weekday()) % 7
        return d + dt.timedelta(days=offset + 7 * (n - 1))
    d = dt.date(year, month, 1) + dt.timedelta(days=32)
    d = dt.date(d.year, d.month, 1) - dt.timedelta(days=1)
    return d - dt.timedelta(days=(d.weekday() - weekday) % 7)


def _observed(d):
    if d.weekday() == 5:
        return d - dt.timedelta(days=1)
    if d.weekday() == 6:
        return d + dt.timedelta(days=1)
    return d


def federal_holidays(year):
    fixed = [dt.date(year, 1, 1), dt.date(year, 6, 19), dt.date(year, 7, 4),
             dt.date(year, 11, 11), dt.date(year, 12, 25)]
    floating = [
        _nth_weekday(year, 1, 0, 3),    # MLK Jr Day
        _nth_weekday(year, 2, 0, 3),    # Washington's Birthday
        _nth_weekday(year, 5, 0, -1),   # Memorial Day
        _nth_weekday(year, 9, 0, 1),    # Labor Day
        _nth_weekday(year, 10, 0, 2),   # Columbus Day
        _nth_weekday(year, 11, 3, 4),   # Thanksgiving
    ]
    return {_observed(d) for d in fixed} | set(floating)


_CACHE = {}


def holiday_set(y0, y1):
    key = (y0, y1)
    if key not in _CACHE:
        s = set()
        for y in range(y0, y1 + 1):
            s |= federal_holidays(y)
        _CACHE[key] = s
    return _CACHE[key]


def business_days(start, end):
    """Mon-Fri business days between two datetimes, excluding federal holidays.

    Same calendar day => 0. Counts days *elapsed*, i.e. business days strictly
    after the ship date up to and including the delivery date.
    """
    a, b = start.date(), end.date()
    if b <= a:
        return 0
    hol = holiday_set(a.year, b.year)
    n, cur = 0, a
    while cur < b:
        cur += dt.timedelta(days=1)
        if cur.weekday() < 5 and cur not in hol:
            n += 1
    return n
