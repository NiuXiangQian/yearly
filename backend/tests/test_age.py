from datetime import date
import pytest
from app.age import age_at, milestones


@pytest.mark.parametrize(
    "birth,taken,label",
    [
        ("2024-02-29", "2024-02-29", "出生当天"),
        ("2024-02-29", "2024-03-01", "出生第 1 天"),
        ("2024-01-31", "2024-02-29", "1 个月"),
        ("2023-01-31", "2023-02-28", "1 个月"),
        ("2024-02-29", "2025-02-28", "1 岁"),
        ("2024-02-29", "2028-02-29", "4 岁"),
        ("2024-01-31", "2024-03-01", "1 个月 1 天"),
        ("2024-01-01", "2024-04-10", "3 个月 9 天"),
        ("2023-08-18", "2026-10-18", "3 岁 2 个月"),
        ("2026-02-18", "2026-10-18", "8 个月"),
        ("2024-03-01", "2024-02-29", "出生前"),
        ("2024-01-01", None, None),
    ],
)
def test_calendar_age(birth, taken, label):
    assert (
        age_at(date.fromisoformat(birth), date.fromisoformat(taken) if taken else None)
        == label
    )


def test_milestones():
    result = {
        x["title"]: x["date"] for x in milestones(date(2024, 1, 31), date(2026, 2, 1))
    }
    assert result["满月"] == "2024-02-29"
    assert result["100 天"] == "2024-05-10"
    assert result["1 岁"] == "2025-01-31"
    assert "3 岁" not in result
