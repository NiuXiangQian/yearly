from datetime import date, timedelta
from dateutil.relativedelta import relativedelta


def age_at(birthday: date, taken: date | None, detailed: bool = False) -> str | None:
    if taken is None:
        return None
    if taken < birthday:
        return "出生前"
    if taken == birthday:
        return "出生当天"
    age = relativedelta(taken, birthday)
    if not age.years and not age.months:
        return f"出生第 {(taken - birthday).days} 天"
    if not age.years:
        return f"{age.months} 个月" + (f" {age.days} 天" if age.days else "")
    label = f"{age.years} 岁" + (f" {age.months} 个月" if age.months else "")
    return label + (f" {age.days} 天" if detailed and age.days else "")


def milestones(birthday: date, through: date):
    markers = [
        ("出生", birthday),
        ("满月", birthday + relativedelta(months=1)),
        ("100 天", birthday + timedelta(days=100)),
        ("6 个月", birthday + relativedelta(months=6)),
    ]
    markers += [
        (f"{n} 岁", birthday + relativedelta(years=n))
        for n in range(1, max(1, through.year - birthday.year + 1))
    ]
    return [
        {"title": title, "date": day.isoformat()}
        for title, day in markers
        if day <= through
    ]
