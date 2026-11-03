from conftest import child, upload


def test_shared_event_relationships_order_and_cover(context):
    a, b = child(context), child(context, "妹妹", "2023-01-01")
    m1, m2 = (
        upload(context, [a["id"]])["media_id"],
        upload(context, [b["id"]])["media_id"],
    )
    client = context.client
    payload = {
        "title": "一起去动物园",
        "content": "共同成长",
        "child_ids": [a["id"], b["id"]],
        "media_ids": [m2, m1],
        "cover_media_id": m2,
        "start_at": "2024-03-31T10:00:00",
        "end_at": "2024-04-02T11:00:00",
    }
    result = client.post("/api/events", json=payload)
    assert result.status_code == 200, result.text
    event = result.json()
    assert event["media_ids"] == [m2, m1]
    assert event["children"][0]["age_start"] != event["children"][1]["age_start"]
    for cid in [a["id"], b["id"]]:
        assert client.get(f"/api/events?child_id={cid}").json()["total"] == 1
    assert (
        client.get(f"/api/events?child_id={a['id']}&child_id={b['id']}").json()["total"]
        == 1
    )
    assert len(client.get(f"/api/events/{event['id']}").json()["media"]) == 2
    payload["child_ids"] = [b["id"]]
    payload["media_ids"] = [m1, m2]
    assert client.put(f"/api/events/{event['id']}", json=payload).status_code == 200
    assert client.get(f"/api/events?child_id={a['id']}").json()["total"] == 0
    assert client.get(f"/api/events/{event['id']}").json()["media_ids"] == [m1, m2]
    assert client.delete(f"/api/events/{event['id']}").status_code == 200
    assert client.get("/api/events").json()["total"] == 0
    assert client.get("/api/media").json()["total"] == 2
    assert len(context.storage.objects) == 2
    assert client.post(f"/api/events/{event['id']}/restore", json={}).status_code == 200
    assert client.get("/api/events").json()["total"] == 1


def test_text_only_and_validation(context):
    client = context.client
    assert (
        client.post(
            "/api/events", json={"title": "第一声爸爸", "content": "只有文字也值得记录"}
        ).status_code
        == 200
    )
    assert (
        client.post(
            "/api/events", json={"title": "错误", "media_ids": [999]}
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/api/events", json={"title": "错误", "cover_media_id": 1}
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/api/events",
            json={
                "title": "错误",
                "start_at": "2024-02-01T00:00:00",
                "end_at": "2024-01-01T00:00:00",
            },
        ).status_code
        == 422
    )


def test_edit_event_preserves_links_to_trashed_media(context):
    mid = upload(context)["media_id"]
    payload = {"title": "记录", "media_ids": [mid], "cover_media_id": mid}
    eid = context.client.post("/api/events", json=payload).json()["id"]
    context.client.delete(f"/api/media/{mid}")
    payload["title"] = "补充后的记录"
    assert context.client.put(f"/api/events/{eid}", json=payload).status_code == 200
    assert context.client.get(f"/api/events/{eid}").json()["media_ids"] == [mid]
    assert context.client.get(f"/api/events/{eid}").json()["media"] == []
