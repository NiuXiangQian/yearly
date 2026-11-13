import json

import pytest
from fastapi import HTTPException
from sqlalchemy import select

from app import memory_interviews as interviews
from app.models import Media, MediaFace, MediaFaceIndex, MediaInterview, MediaSearchIndex
from app.face_engine import MODEL_VERSION
from conftest import child, upload
from test_accounts import act
from test_faces import image_media, face, detector


@pytest.fixture
def interviewer(monkeypatch):
    calls = []
    def respond(db, system, content, schema):
        context = json.loads(content)
        calls.append(context)
        answering = bool(context["new_answers"])
        return schema(question="这次滑滑梯有什么想留下的细节？" if answering else "这次去公园有什么特别的事？",
            options=["和家人散步", "暂时不清楚"], tags=[
                dict(name="公园", source="visual", evidence="公园"),
                dict(name="滑滑梯", source="answer", evidence="滑滑梯"),
                dict(name="海边", source="visual", evidence="海边"),
                dict(name="小宝", source="visual", evidence="公园"),
            ])
    monkeypatch.setattr(interviews, "chat", respond)
    return calls


def memory(context):
    person = child(context, "小宝")
    mid = upload(context, [person["id"]])["media_id"]
    with context.db() as db:
        db.get(Media, mid).tags = ["原有标签"]
        db.get(Media, mid).remark = "原有小记"
        db.add(MediaSearchIndex(media_id=mid, status="ready", description="孩子在公园里玩耍。", embedding=[1] + [0]*511))
        db.commit()
    return mid, person


@pytest.mark.parametrize("role", ["member", "viewer"])
def test_admin_guards_cover_queues_interviews_and_batch(context, interviewer, role):
    mid, _ = memory(context)
    act(context, role)
    for method, path, body in [
        ("GET", "/api/faces/review", None), ("POST", "/api/faces/analyze-next", {}),
        ("GET", "/api/memory-interviews", None), ("GET", f"/api/memory-interviews/{mid}", None),
        ("POST", f"/api/memory-interviews/{mid}/prepare", {}),
        ("POST", f"/api/memory-interviews/{mid}/reply", {"answer": "你好"}),
        ("POST", f"/api/memory-interviews/{mid}/apply", {}),
        ("PUT", f"/api/memory-interviews/{mid}/people", {"child_ids": []}),
    ]:
        assert context.client.request(method, path, json=body).status_code == 403
    assert interviewer == []


def test_cached_proposals_have_evidence_and_do_not_change_legacy_media(context, interviewer):
    mid, _ = memory(context)
    old = context.client.get(f"/api/media/{mid}").json()
    assert context.client.get(f"/api/memory-interviews/{mid}").json()["status"] == "not_started"
    assert interviewer == []
    first = context.client.post(f"/api/memory-interviews/{mid}/prepare", json={})
    assert first.status_code == 200, first.text
    value = first.json()
    assert value["suggestions"]["tags"] == [dict(name="公园", source="visual", evidence="公园")]
    assert value["suggestions"]["story"] == ""
    with context.db() as db:
        draft = db.get(MediaInterview, mid)
        draft.suggestions = dict(draft.suggestions, story="旧建议里未经管理员确认的画面故事")
        db.commit()
    assert context.client.get(f"/api/memory-interviews/{mid}").json()["suggestions"]["story"] == ""
    assert value["confirmed_people"] == []  # Whole-photo associations are not confirmed identities.
    assert context.client.get(f"/api/media/{mid}").json() == old
    assert context.client.post(f"/api/memory-interviews/{mid}/prepare", json={}).json()["cached"]
    assert len(interviewer) == 1
    with context.db() as db:
        db.get(Media, mid).title = "新标题"
        db.commit()
    assert context.client.get(f"/api/memory-interviews/{mid}").json()["outdated"]
    assert len(interviewer) == 1
    assert context.client.post(f"/api/memory-interviews/{mid}/prepare", json={}).status_code == 200
    assert len(interviewer) == 2


def test_followup_review_apply_and_continue_preserve_notes_profiles_and_audit(context, interviewer):
    mid, person = memory(context)
    context.client.post(f"/api/memory-interviews/{mid}/prepare", json={})
    reply = context.client.post(f"/api/memory-interviews/{mid}/reply", json={"answer": "奶奶陪她在公园滑滑梯"})
    assert reply.status_code == 200, reply.text
    value = reply.json()
    assert value["messages"][-2] == dict(role="user", content="奶奶陪她在公园滑滑梯")
    assert "滑滑梯" in value["suggestions"]["question"]
    assert {tag["name"] for tag in value["suggestions"]["tags"]} == {"公园", "滑滑梯"}
    old = context.client.get(f"/api/media/{mid}").json()
    assert old["tags"] == ["原有标签"] and old["remark"] == "原有小记"
    body = dict(tags=["滑滑梯"], remark_addition="奶奶陪她在公园滑滑梯")
    saved = context.client.post(f"/api/memory-interviews/{mid}/apply", json=body)
    assert saved.status_code == 200, saved.text
    assert saved.json()["status"] == "completed" and not saved.json()["outdated"]
    updated = context.client.get(f"/api/media/{mid}").json()
    assert updated["tags"] == ["原有标签", "滑滑梯"]
    assert updated["remark"] == "原有小记\n奶奶陪她在公园滑滑梯"
    assert updated["child_ids"] == [person["id"]]
    context.client.post(f"/api/memory-interviews/{mid}/apply", json=body)
    assert context.client.get(f"/api/media/{mid}").json()["remark"] == updated["remark"]
    assert context.client.get("/api/memory-interviews").json()["items"] == []
    assert len(context.client.get("/api/memory-interviews?scope=all").json()["items"]) == 1
    again = context.client.post(f"/api/memory-interviews/{mid}/reply", json={"answer": "回家一起看了绘本"})
    assert again.status_code == 200
    assert interviewer[-1]["new_answers"] == "回家一起看了绘本"
    assert again.json()["suggestions"]["story"] == "回家一起看了绘本"
    logs = context.client.get(f"/api/audit-logs?resource_type=media&resource_id={mid}").json()["items"]
    assert all(isinstance(v, dict) for row in logs for v in row["changes"].values())


def test_provider_failure_keeps_draft_and_blank_answer_is_rejected(context, interviewer, monkeypatch):
    mid, _ = memory(context)
    first = context.client.post(f"/api/memory-interviews/{mid}/prepare", json={}).json()
    def fail(*args):raise HTTPException(429, "本月预算已用完")
    monkeypatch.setattr(interviews, "chat", fail)
    assert context.client.post(f"/api/memory-interviews/{mid}/reply", json={"answer": "补充文字"}).status_code == 429
    assert context.client.get(f"/api/memory-interviews/{mid}").json()["messages"] == first["messages"]
    assert context.client.post(f"/api/memory-interviews/{mid}/reply", json={"answer": "  "}).status_code == 422
    assert context.client.post(f"/api/memory-interviews/{mid}/apply", json={"tags": ["a"*81]}).status_code == 422


def test_queue_pagination_confirmation_and_identity_questions(context, interviewer):
    person = child(context, "小宝")
    media_ids, face_ids = [], []
    for _ in range(3):
        mid = upload(context)["media_id"]
        with context.db() as db:
            from app.models import MediaFile
            source = db.scalar(select(MediaFile).where(MediaFile.media_id == mid))
            db.add(MediaFaceIndex(media_id=mid, model=MODEL_VERSION, source_sha256=source.sha256));db.flush()
            row = MediaFace(media_id=mid, **face());db.add(row);db.commit();face_ids.append(row.id)
        media_ids.append(mid)
    context.client.put(f"/api/faces/media/{media_ids[0]}/confirm", json={"assignments": [dict(face_id=face_ids[0], child_id=person["id"])]})
    first = context.client.get("/api/faces/review?limit=1").json()
    assert first["pending_faces"] == 2 and len(first["items"]) == 1
    assert first["items"][0]["candidates"][0]["child_id"] == person["id"]
    second = context.client.get(f"/api/faces/review?limit=1&before={first['next_cursor']}").json()
    assert second["items"][0]["id"] != first["items"][0]["id"]
    assert second["next_cursor"] is None
    interview = context.client.get(f"/api/memory-interviews/{media_ids[2]}").json()
    assert "小宝" in interview["identity_questions"][0]["question"] and interview["confirmed_people"] == []
    confirm = context.client.put(f"/api/faces/media/{media_ids[2]}/confirm", json={"assignments": [dict(face_id=face_ids[2], child_id=person["id"])]})
    assert confirm.status_code == 200
    updated = context.client.get(f"/api/memory-interviews/{media_ids[2]}").json()
    assert updated["identity_questions"] == [] and updated["confirmed_people"] == ["小宝"]
    assert len(context.client.get(f"/api/faces/review?media_id={media_ids[2]}").json()["items"]) == 0


def test_batch_analysis_does_not_need_opening_each_photo(context, detector):
    mids = [image_media(context) for _ in range(2)]
    assert context.client.get("/api/faces/review").json()["unanalysed_photos"] == 2
    first = context.client.post("/api/faces/analyze-next?limit=1", json={})
    assert first.status_code == 200, first.text
    assert first.json()["remaining"] == 1
    second = context.client.post("/api/faces/analyze-next?limit=5", json={}).json()
    assert second["remaining"] == 0
    assert set(first.json()["processed"] + second["processed"]) == set(mids)
    assert context.client.get("/api/faces/review").json()["pending_faces"] == 2
    assert context.client.post("/api/faces/analyze-next", json={}).json()["processed"] == []
    assert len(detector) == 2


def test_manual_people_links_do_not_seed_face_identity_and_invalidate_suggestions(context, interviewer):
    mid, person = memory(context)
    other = child(context, "奶奶")
    context.client.post(f"/api/memory-interviews/{mid}/prepare", json={})
    response = context.client.put(f"/api/memory-interviews/{mid}/people", json={"child_ids": [person["id"], other["id"]]})
    assert response.status_code == 200, response.text
    assert set(response.json()["media"]["child_ids"]) == {person["id"], other["id"]}
    assert response.json()["outdated"] and response.json()["confirmed_people"] == []
    assert context.client.get(f"/api/media/{mid}").json()["tags"] == ["原有标签"]
