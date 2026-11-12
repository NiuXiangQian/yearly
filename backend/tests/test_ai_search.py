import io
import json
from decimal import Decimal
from types import SimpleNamespace

import httpx
import pytest
from PIL import Image
from fastapi import HTTPException
from sqlalchemy import select
from app import ai_search as ai
from app.config import settings
from app.models import AISpend, MediaSearchIndex, Media, MediaFile, DisplayPreview, VideoPreview
from conftest import upload, child, file_payload
from test_accounts import act


def vector(value=1):
    return [value] + [0] * (ai.DIMENSIONS - 1)


@pytest.fixture
def provider(monkeypatch):
    monkeypatch.setattr(settings(), "ai_search_enabled", True)
    monkeypatch.setattr(settings(), "openai_api_key", "test-key")
    monkeypatch.setattr(settings(), "ai_monthly_budget_usd", 80)
    calls = []
    def request(db, endpoint, payload):
        calls.append((endpoint, payload))
        if endpoint == "embeddings":
            return {"data": [{"embedding": vector()}]}
        schema = payload.get("response_format", {}).get("json_schema", {}).get("name")
        if schema in ("QueryPlan", "SearchSelection"):
            plan = dict(scene="海边玩沙", start=None, end=None, profile_ids=[], media_type=None)
            if schema == "SearchSelection":
                candidates = json.loads(payload["messages"][1]["content"])["candidates"]
                plan["ids"] = [c["id"] for c in candidates if "海边" in c["description"]]
            content = json.dumps(plan)
        elif schema == "Matches":
            candidates = json.loads(payload["messages"][1]["content"])["candidates"]
            content = json.dumps({"ids": [c["id"] for c in candidates if "海边" in c["description"]]})
        else:
            content = "海边玩沙的孩子，旁边有蓝色小桶。"
        return {"choices": [{"finish_reason": "stop", "message": {"content": content}}]}
    monkeypatch.setattr(ai, "openai_call", request)
    return calls


def add_index(context, mid, description="海边玩沙", embedding=None):
    with context.db() as db:
        db.add(MediaSearchIndex(media_id=mid, status="ready", description=description, embedding=embedding or vector()))
        db.commit()


def test_search_semantics_filters_and_old_contract(context, provider):
    person = child(context)
    first = upload(context, [person["id"]], files=[file_payload(name="clip.mov")], media_type="video")["media_id"]
    other = upload(context)["media_id"]
    add_index(context, first)
    add_index(context, other, "室内睡觉", vector(-1))
    legacy = context.client.get("/api/media").json()
    assert legacy["total"] == 2
    assert "embedding" not in legacy["items"][0]
    response = context.client.post("/api/ai-search", json={"query": "海边玩沙的视频", "child_ids": [person["id"]], "media_type": "video"})
    assert response.status_code == 200, response.text
    assert [x["id"] for x in response.json()["items"]] == [first]
    assert response.json()["items"][0]["files"]
    assert "oss_object_key" not in response.text and "embedding" not in response.text
    assert context.client.get("/api/media").json() == legacy
    assert context.client.post("/api/ai-search", json={"query": "海边", "start": "2030-01-01T00:00:00"}).json()["items"] == []


@pytest.mark.parametrize("role", ["member", "viewer"])
def test_permissions_before_provider(context, provider, role):
    visible = upload(context)["media_id"]
    hidden = upload(context)["media_id"]
    deleted = upload(context)["media_id"]
    for mid in (visible, hidden, deleted):
        add_index(context, mid, "海边" if mid == visible else "private-caption")
    with context.db() as db:
        db.get(Media, hidden).share_allowed = False
        db.get(Media, deleted).status = "deleted"
        db.commit()
    act(context, role)
    status = context.client.get("/api/ai-search/status").json()
    assert status["indexed"] == 1 and status["total"] == 1
    response = context.client.post("/api/ai-search", json={"query": "海边"})
    assert response.status_code == 200
    assert [item["id"] for item in response.json()["items"]] == [visible]
    assert "private-caption" not in json.dumps(provider)


def test_hidden_folder_and_day_not_searchable(context, provider):
    from app.models import TimelineDay
    hidden = upload(context, timeline_date="2024-03-31")["media_id"]
    add_index(context, hidden, "private-caption")
    with context.db() as db:
        db.add(TimelineDay(timeline_date=__import__('datetime').date(2024,3,31), share_allowed=False))
        db.commit()
    act(context, "viewer")
    assert context.client.post("/api/ai-search", json={"query":"海边"}).json()["items"] == []
    assert provider == []


def test_empty_disabled_and_failed_provider(context, provider, monkeypatch):
    assert context.client.post("/api/ai-search", json={"query":"  "}).status_code == 422
    assert context.client.post("/api/ai-search", json={"query":"海边"}).json()["items"] == []
    mid = upload(context)["media_id"]
    add_index(context, mid, "室内睡觉")
    assert context.client.post("/api/ai-search", json={"query":"海边"}).json()["items"] == []
    monkeypatch.setattr(settings(), "ai_search_enabled", False)
    assert context.client.post("/api/ai-search", json={"query":"海边"}).status_code == 503
    assert context.client.get("/api/timeline").status_code == 200


def test_monthly_budget_and_accounting(context, monkeypatch):
    monkeypatch.setattr(settings(), "ai_search_enabled", True)
    monkeypatch.setattr(settings(), "openai_api_key", "test-key")
    monkeypatch.setattr(settings(), "ai_monthly_budget_usd", 0.05)
    payloads = []
    def post(self, url, **kwargs):
        payloads.append(kwargs["json"])
        return httpx.Response(200, request=httpx.Request("POST", url), json={"usage":{"prompt_tokens":1000,"completion_tokens":100},"choices":[]})
    monkeypatch.setattr(httpx.Client, "post", post)
    with context.db() as db:
        ai.openai_call(db, "chat/completions", {})
        amount = db.scalar(select(AISpend.amount))
        assert amount == Decimal("0.000560")
        with pytest.raises(HTTPException) as failure:
            ai.openai_call(db, "chat/completions", {})
        assert failure.value.status_code == 429
        assert len(payloads) == 1


def test_index_uses_previews_and_does_not_repeat(context, provider):
    mid = upload(context)["media_id"]
    image = Image.new("RGB", (256, 256), "blue")
    raw = io.BytesIO(); image.save(raw, "PNG")
    reads = []
    class Bucket:
        def get_object(self, key):
            reads.append(key)
            assert key == "previews/test.webp"
            return io.BytesIO(raw.getvalue())
    context.storage.bucket = Bucket()
    with context.db() as db:
        assert ai.index_one(db, context.storage) is False
        file = db.scalar(select(MediaFile).where(MediaFile.media_id == mid))
        db.add(DisplayPreview(sha256=file.sha256,status="ready",image_key="previews/test.webp"))
        db.commit()
        assert ai.index_one(db, context.storage) is True
        assert db.get(MediaSearchIndex, mid).status == "ready"
        assert db.get(MediaSearchIndex, mid).analysis_model == settings().ai_analysis_model
        assert ai.index_one(db, context.storage) is False
    assert reads == ["previews/test.webp"]


def test_rejects_incomplete_or_invalid_provider_output(monkeypatch):
    monkeypatch.setattr(ai,"openai_call",lambda *args: {"choices":[{"finish_reason":"length","message":{"content":"{}"}}]})
    with pytest.raises(HTTPException): ai.chat(None,"system","user",ai.QueryPlan)
    monkeypatch.setattr(ai,"openai_call",lambda *args: {"data":[{"embedding":[float('nan')]*ai.DIMENSIONS}]})
    with pytest.raises(HTTPException): ai.embed(None,"text")


def test_image_input_is_resized_and_contains_no_metadata():
    source = io.BytesIO()
    Image.new("RGB",(2000,1000),"blue").save(source,"PNG")
    payload = ai.image_input(source.getvalue())
    import base64
    image = Image.open(io.BytesIO(base64.b64decode(payload['image_url']['url'].split(',')[1])))
    assert image.size == (768,384)
    assert not image.getexif()


def test_inferred_date_person_and_type_are_intersected(context, provider, monkeypatch):
    person = child(context)
    wanted = upload(context, [person['id']], taken='2025-07-12T10:00:00')['media_id']
    old = upload(context, [person['id']], taken='2024-07-12T10:00:00')['media_id']
    other = upload(context, taken='2025-07-12T10:00:00')['media_id']
    for mid in (wanted, old, other): add_index(context, mid)
    real_chat = ai.chat
    def planned(db, system, content, schema=None):
        if schema in (ai.QueryPlan, ai.SearchSelection):
            return schema(**({"ids": [wanted, old, other]} if schema is ai.SearchSelection else {}), scene='', start='2025-06-01',end='2025-08-31',profile_ids=[person['id']],media_type='photo')
        return real_chat(db,system,content,schema)
    monkeypatch.setattr(ai,'chat',planned)
    response=context.client.post('/api/ai-search',json={'query':'去年夏天哥哥的照片'})
    assert response.status_code == 200, response.text
    assert [item['id'] for item in response.json()['items']] == [wanted]
    response=context.client.post('/api/ai-search',json={'query':'去年夏天哥哥的照片','end':'2025-01-01T00:00:00'})
    assert response.json()['items'] == []


def test_small_scope_uses_one_call_and_reports_owned_progress(context, provider):
    mid = upload(context)["media_id"]
    add_index(context, mid)
    response = context.client.post("/api/ai-search", json={"query":"海边", "request_id":"my-search"})
    assert response.status_code == 200
    assert len(provider) == 1
    assert context.client.get("/api/ai-search/progress/my-search").json() == {"stage":"complete"}
    act(context,"viewer")
    assert context.client.get("/api/ai-search/progress/my-search").json() == {"stage":"waiting"}


def test_large_scope_preserves_vector_search_and_scope(context, provider):
    for _ in range(41): add_index(context, upload(context)["media_id"])
    response=context.client.post("/api/ai-search",json={"query":"海边"})
    assert response.status_code == 200
    assert len(response.json()["items"]) == 40
    assert [c[0] for c in provider] == ["chat/completions","embeddings","chat/completions"]


@pytest.mark.parametrize("duration,expected",[(12,6),(120,24),(600,60)])
def test_video_frame_coverage_scales_with_duration(tmp_path,monkeypatch,duration,expected):
    import shutil,subprocess
    source=tmp_path/"preview.mp4"
    subprocess.run([ai.imageio_ffmpeg.get_ffmpeg_exe(),"-hide_banner","-loglevel","error","-f","lavfi","-i",
                    "color=c=blue:s=16x16:r=1","-t",str(duration),"-c:v","libx264","-threads","1",str(source)],check=True)
    storage=SimpleNamespace(bucket=SimpleNamespace(get_object_to_file=lambda key,target:shutil.copyfile(source,target)))
    db=SimpleNamespace(get=lambda *args:SimpleNamespace(object_key="previews/video.mp4"))
    captured=[]
    monkeypatch.setattr(ai,"chat",lambda db,system,content,**kwargs: captured.extend(content) or "蓝色画面")
    monkeypatch.setattr(ai,"embed",lambda *args:vector())
    description,embedding,seconds=ai.analyze_media(db,storage,SimpleNamespace(media_type="video",duration_ms=duration*1000),SimpleNamespace(sha256="test"))
    assert len(seconds)==expected
    assert seconds[-1] >= duration*.8
    assert len([x for x in captured if x["type"]=="image_url"])==expected


def test_parallel_budget_reservations_do_not_deadlock_or_exceed_limit(mysql_engine, monkeypatch):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Barrier
    from uuid import uuid4
    from sqlalchemy import delete
    from sqlalchemy.orm import sessionmaker
    month = 'T' + uuid4().hex[:6]
    monkeypatch.setattr(ai, 'datetime', SimpleNamespace(now=lambda tz: SimpleNamespace(strftime=lambda fmt: month)))
    monkeypatch.setattr(settings(), 'ai_search_enabled', True)
    monkeypatch.setattr(settings(), 'openai_api_key', 'test-key')
    monkeypatch.setattr(settings(), 'ai_monthly_budget_usd', 0.02)
    monkeypatch.setattr(httpx.Client, 'post', lambda self, url, **kwargs: httpx.Response(200, request=httpx.Request('POST', url), json={'data': []}))
    factory = sessionmaker(bind=mysql_engine, expire_on_commit=False)
    barrier = Barrier(8)
    def reserve(_):
        barrier.wait()
        with factory() as db:
            try:
                ai.openai_call(db, 'embeddings', {})
                return 'sent'
            except HTTPException as exc:
                assert exc.status_code == 429
                return 'budget'
    try:
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(reserve, range(8)))
        assert results.count('sent') == 4
        assert results.count('budget') == 4
        with factory() as db:
            assert db.get(AISpend, month).amount == Decimal('0.020000')
    finally:
        with factory() as db:
            db.execute(delete(AISpend).where(AISpend.month == month)); db.commit()


def test_analysis_and_online_search_use_separate_models(monkeypatch):
    payloads=[]
    def request(db, endpoint, payload):
        payloads.append(payload)
        return {"choices":[{"finish_reason":"stop","message":{"content":"画面描述"}}]}
    monkeypatch.setattr(ai,"openai_call",request)
    ai.chat(None,"system","query")
    ai.chat(None,"system","image",model="gpt-6.1-sol")
    assert payloads[0]["model"]=="gpt-4.1-mini"
    assert payloads[0]["temperature"]==0
    assert payloads[1]["model"]=="gpt-6.1-sol"
    assert payloads[1]["reasoning_effort"]=="low"
    assert payloads[1]["max_completion_tokens"]==3000
    assert "temperature" not in payloads[1] and "max_tokens" not in payloads[1]


@pytest.mark.parametrize("model,expected",[("gpt-4.1-mini","0.000500"),("gpt-6.1-sol","0.002620")])
def test_model_specific_cached_token_accounting(mysql_engine,monkeypatch,model,expected):
    from uuid import uuid4
    from sqlalchemy import delete
    from sqlalchemy.orm import sessionmaker
    month='T'+uuid4().hex[:6]
    monkeypatch.setattr(ai,'datetime',SimpleNamespace(now=lambda tz:SimpleNamespace(strftime=lambda fmt:month)))
    monkeypatch.setattr(settings(),'ai_search_enabled',True)
    monkeypatch.setattr(settings(),'openai_api_key','test-key')
    monkeypatch.setattr(settings(),'ai_monthly_budget_usd',0.1 if model=='gpt-6.1-sol' else 80)
    monkeypatch.setattr(httpx.Client,'post',lambda self,url,**kwargs:httpx.Response(200,request=httpx.Request('POST',url),json={"usage":{"prompt_tokens":1000,"prompt_tokens_details":{"cached_tokens":200},"completion_tokens":100}}))
    factory=sessionmaker(bind=mysql_engine,expire_on_commit=False)
    try:
        with factory() as db:
            ai.openai_call(db,'chat/completions',{'model':model})
            db.expire_all()
            assert db.get(AISpend,month).amount==Decimal(expected)
            if model=='gpt-6.1-sol':
                with pytest.raises(HTTPException) as failure:
                    ai.openai_call(db,'chat/completions',{'model':model})
                assert failure.value.status_code==429
    finally:
        with factory() as db:db.execute(delete(AISpend).where(AISpend.month==month));db.commit()
