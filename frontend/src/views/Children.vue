<script setup lang="ts">
import { ref } from "vue";
import { useRouter } from "vue-router";
import {
  Plus,
  ArrowUpRight,
  Baby,
  CalendarDays,
  Heart,
  Pencil,
} from "lucide-vue-next";
import { useYearly } from "../stores/yearly";
import { api, post, put, del, notify, localDate } from "../lib/api";
import EmptyState from "../components/EmptyState.vue";
import ChildAvatar from "../components/ChildAvatar.vue";
const yearly = useYearly(),
  router = useRouter(),
  open = ref(false),
  form = ref<any>({}),
  editing = ref<number | null>(null),
  confirmation = ref(""),
  deleteOpen = ref(false),
  busy = ref(false),
  avatarOptions = ref<any[]>([]);
function edit(c?: any) {
  editing.value = c?.id || null;
  form.value = c
    ? { ...c }
    : {
        name: "",
        nickname: "",
        birthday: "",
        birth_time: null,
        gender: null,
        description: "",
        theme_color: "#8c9c7b",
        sort_order: yearly.children.length,
        status: "active",
        avatar_media_id: null,
      };
  open.value = true;
  avatarOptions.value = [];
}
async function searchAvatar(q: string) {
  try {
    avatarOptions.value = (
      await api(
        "/media?" +
          new URLSearchParams({ q, media_type: "photo", page_size: "30" }),
      )
    ).items;
  } catch (e) {
    notify(e);
  }
}
async function save() {
  busy.value = true;
  try {
    const data = { ...form.value, birth_time: form.value.birth_time || null };
    editing.value
      ? await put("/children/" + editing.value, data)
      : await post("/children", data);
    open.value = false;
    await yearly.load();
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
  }
}
async function remove() {
  try {
    await del(
      `/children/${editing.value}?confirm_name=${encodeURIComponent(confirmation.value)}`,
    );
    open.value = false;
    deleteOpen.value = false;
    yearly.selected = yearly.selected.filter((id) => id !== editing.value);
    await yearly.load();
  } catch (e) {
    notify(e);
  }
}
function browse(id: number) {
  yearly.selected = [id];
  router.push("/");
}
</script>
<template>
  <div class="page-heading">
    <div>
      <span class="eyebrow">SMALL PEOPLE, BIG WORLDS</span>
      <h1>每个孩子，独一份成长。</h1>
      <p>生日是故事的起点，每一段时光都有自己的名字。</p>
    </div>
    <button v-if="yearly.canEdit" class="button primary" @click="edit()">
      <Plus :size="17" />添加孩子
    </button>
  </div>
  <div v-if="yearly.children.length" class="children-grid">
    <article
      v-for="c in yearly.children"
      :key="c.id"
      class="child-profile-card"
      :style="{ '--child-color': c.theme_color }"
    >
      <div class="child-card-top">
        <ChildAvatar class="big-child-avatar" :child="c" /><span class="chip">{{
          c.status === "archived" ? "已归档" : "正在长大"
        }}</span>
      </div>
      <h2>
        {{ c.nickname || c.name }}<small v-if="c.nickname">{{ c.name }}</small>
      </h2>
      <p>
        <CalendarDays :size="15" />{{ localDate(c.birthday)
        }}<span v-if="c.birth_time">{{ c.birth_time }}</span>
      </p>
      <p class="child-description">
        {{ c.description || "小小的你，正在创造大大的世界。" }}
      </p>
      <div class="child-card-actions">
        <button class="text-button" @click="browse(c.id)">
          翻开成长时间线<ArrowUpRight :size="16" /></button
        ><button
          v-if="yearly.canEdit"
          class="icon-button"
          aria-label="编辑孩子档案"
          @click="edit(c)"
        >
          <Pencil :size="16" />
        </button>
      </div>
    </article>
  </div>
  <EmptyState
    v-else
    title="从一个名字，开始一段故事"
    description="添加孩子的名字和生日，照片便能标记当时的年龄。"
    ><button v-if="yearly.canEdit" class="button primary" @click="edit()">
      <Plus :size="16" />创建孩子档案
    </button></EmptyState
  >
  <ElDialog
    v-model="open"
    :title="editing ? '编辑孩子档案' : '认识一个小小的你'"
    width="660px"
    ><form @submit.prevent="save">
      <div class="form-row">
        <label
          >名字<input
            v-model="form.name"
            maxlength="80"
            required
            placeholder="孩子的名字" /></label
        ><label
          >昵称<input
            v-model="form.nickname"
            maxlength="80"
            placeholder="家里怎么称呼 TA"
        /></label>
      </div>
      <div class="form-row">
        <label
          >出生日期<input v-model="form.birthday" type="date" required /></label
        ><label
          >出生时刻（可选）<input
            v-model="form.birth_time"
            type="time"
            step="1"
        /></label>
      </div>
      <div class="form-row">
        <label
          >性别（可选）<select v-model="form.gender">
            <option :value="null">暂不填写</option>
            <option value="男">男</option>
            <option value="女">女</option>
            <option value="其他">其他</option>
          </select></label
        ><label
          >时间线标识颜色<input v-model="form.theme_color" type="color"
        /></label>
      </div>
      <label
        >关于孩子<textarea
          v-model="form.description"
          rows="3"
          placeholder="性格、爱好，或你想对 TA 说的话…"
        /></label
      ><label
        >头像媒体<ElSelect
          v-model="form.avatar_media_id"
          filterable
          remote
          clearable
          :remote-method="searchAvatar"
          placeholder="搜索已上传照片标题"
          @visible-change="(v: boolean) => v && searchAvatar('')"
          ><ElOption
            v-if="
              form.avatar_media_id &&
              !avatarOptions.some((m) => m.id === form.avatar_media_id)
            "
            :value="form.avatar_media_id"
            :label="'当前头像 #' + form.avatar_media_id" /><ElOption
            v-for="m in avatarOptions"
            :key="m.id"
            :value="m.id"
            :label="m.title || '照片 #' + m.id" /></ElSelect
      ></label>
      <div class="form-row">
        <label
          >显示顺序<input
            type="number"
            v-model.number="form.sort_order" /></label
        ><label
          >档案状态<select v-model="form.status">
            <option value="active">启用</option>
            <option value="archived">归档</option>
          </select></label
        >
      </div>
      <p class="muted">修改生日后，历史影像上的年龄会自动重新计算。</p>
      <div class="dialog-actions">
        <button
          v-if="editing && yearly.isAdmin"
          type="button"
          class="text-button danger"
          @click="
            confirmation = '';
            deleteOpen = true;
          "
        >
          删除档案</button
        ><button type="button" class="button" @click="open = false">取消</button
        ><button class="button primary" :disabled="busy">
          {{ busy ? "正在保存…" : "保存孩子档案" }}
        </button>
      </div>
    </form></ElDialog
  ><ElDialog v-model="deleteOpen" title="确认删除孩子档案" width="480px"
    ><p>删除会解除 TA 与照片、日记的关联。家庭原件会继续保留。</p>
    <label
      >再次输入孩子名字「{{ form.name }}」<input v-model="confirmation"
    /></label>
    <div class="dialog-actions">
      <button class="button" @click="deleteOpen = false">取消</button
      ><button
        class="button danger-button"
        :disabled="confirmation !== form.name"
        @click="remove"
      >
        确认删除档案
      </button>
    </div></ElDialog
  >
</template>
