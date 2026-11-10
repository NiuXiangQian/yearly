<script setup lang="ts">
import { t } from "../lib/i18n";
import {
  hasGrowthTimeline,
  personRelationships,
  petSpecies,
  profileCategories,
  matchesProfile,
} from "../lib/profiles";
import DateField from "../components/DateField.vue";
import { computed, ref, watch } from "vue";
import { useRouter } from "vue-router";
import {
  Plus,
  ArrowUpRight,
  PawPrint,
  CalendarDays,
  Pencil,
  Upload,
} from "lucide-vue-next";
import { useYearly } from "../stores/yearly";
import { api, post, put, del, notify, localDate } from "../lib/api";
import EmptyState from "../components/EmptyState.vue";
import ChildAvatar from "../components/ChildAvatar.vue";
import { inspectFile } from "../lib/metadata";
import { directUpload } from "../lib/upload";
const yearly = useYearly(),
  router = useRouter(),
  open = ref(false),
  form = ref<any>({}),
  editing = ref<number | null>(null),
  confirmation = ref(""),
  deleteOpen = ref(false),
  busy = ref(false),
  avatarOptions = ref<any[]>([]);
const growthTouched = ref(false);
watch(
  () => form.value.relationship,
  (relationship) => {
    if (
      !editing.value &&
      !growthTouched.value &&
      form.value.profile_type === "person"
    )
      form.value.growth_enabled = relationship === "孩子";
  },
);
const category = ref(""),
  search = ref("");
const categories = computed(() => profileCategories(yearly.children));
const visibleProfiles = computed(() =>
  yearly.children.filter((p) =>
    matchesProfile(p, category.value, search.value),
  ),
);
const avatarInput = ref<HTMLInputElement>(),
  avatarFile = ref<File | null>(null),
  avatarPreview = ref(""),
  avatarPreparing = ref(false),
  avatarProgress = ref<number | null>(null);
function clearAvatarDraft() {
  avatarFile.value = null;
  if (avatarPreview.value) URL.revokeObjectURL(avatarPreview.value);
  avatarPreview.value = "";
}
watch(open, (value) => {
  if (!value) clearAvatarDraft();
});
async function chooseAvatar(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  input.value = "";
  if (!file) return;
  avatarPreparing.value = true;
  try {
    if (file.size > 20 * 1024 * 1024)
      throw new Error(t("请选择 20 MB 以内的头像图片"));
    if (!/\.(jpe?g|png|webp|heic|heif)$/i.test(file.name))
      throw new Error(t("请选择 JPG、PNG、WebP 或 HEIC 图片"));
    let source: Blob = file;
    if (/\.hei[cf]$/i.test(file.name)) {
      const { heicTo } = await import("heic-to/csp");
      source = await heicTo({ blob: file, type: "image/jpeg", quality: 0.9 });
    }
    const image = await createImageBitmap(source);
    const side = Math.min(image.width, image.height);
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = Math.min(512, side);
    canvas
      .getContext("2d")!
      .drawImage(
        image,
        (image.width - side) / 2,
        (image.height - side) / 2,
        side,
        side,
        0,
        0,
        canvas.width,
        canvas.height,
      );
    image.close();
    const blob = await new Promise<Blob>((resolve, reject) =>
      canvas.toBlob(
        (value) =>
          value
            ? resolve(value)
            : reject(new Error(t("头像处理失败，请换一张图片"))),
        "image/jpeg",
        0.85,
      ),
    );
    if (!open.value) return;
    clearAvatarDraft();
    avatarFile.value = new File([blob], "avatar.jpg", { type: "image/jpeg" });
    avatarPreview.value = URL.createObjectURL(blob);
  } catch (e) {
    notify(e);
  } finally {
    avatarPreparing.value = false;
  }
}
function edit(c?: any, profileType = "person") {
  clearAvatarDraft();
  editing.value = c?.id || null;
  growthTouched.value = false;
  form.value = c
    ? {
        species: "",
        breed: "",
        ...c,
        growth_enabled: hasGrowthTimeline(c),
        profile_type: c.profile_type === "pet" ? "pet" : "person",
        relationship:
          c.relationship ||
          (c.profile_type === "child" || !c.profile_type ? "孩子" : ""),
      }
    : {
        profile_type: profileType,
        growth_enabled: profileType === "pet",
        relationship: "",
        species: "",
        breed: "",
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
  if (busy.value || avatarPreparing.value) return;
  busy.value = true;
  try {
    if (avatarFile.value) {
      avatarProgress.value = 0;
      const item = await inspectFile(avatarFile.value);
      const result = await post("/uploads", {
        purpose: "avatar",
        media_type: "photo",
        files: [
          {
            original_filename: item.file.name,
            mime_type: item.file.type,
            file_size: item.file.size,
            ...item.hash,
            file_role: "original",
          },
        ],
      });
      for (const task of result.tasks)
        await directUpload(task, item, (value) => {
          avatarProgress.value = value;
        });
      form.value.avatar_media_id = result.media_id;
      avatarFile.value = null;
    }
    const data = {
      ...form.value,
      birthday: form.value.birthday || null,
      birth_time: form.value.birth_time || null,
    };
    editing.value
      ? await put("/children/" + editing.value, data)
      : await post("/children", data);
    open.value = false;
    category.value = "";
    search.value = "";
    await yearly.load();
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
    avatarProgress.value = null;
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
      <span class="eyebrow">LITTLE LIVES, SHARED STORIES</span>
      <h1>{{ t("每一位家人，都在时光里。") }}</h1>
      <p>
        {{ t("记录爸爸妈妈、长辈、孩子和宠物，按名字或分类找到共同回忆。") }}
      </p>
    </div>
    <div v-if="yearly.canEdit" class="profile-create-actions">
      <button class="button" @click="edit(undefined, 'pet')">
        <PawPrint :size="17" /> {{ t("添加宠物") }}
      </button>
      <button class="button primary" @click="edit()">
        <Plus :size="17" /> {{ t("添加人物") }}
      </button>
    </div>
  </div>
  <div v-if="yearly.children.length" class="profile-list-filters">
    <input
      v-model="search"
      type="search"
      :aria-label="t('搜索人物或宠物')"
      :placeholder="t('搜索名字、关系、分类')"
    />
    <select v-model="category" :aria-label="t('档案分类')">
      <option v-for="item in categories" :key="item.value" :value="item.value">
        {{ item.label }}
      </option>
    </select>
  </div>
  <p v-if="yearly.children.length && !visibleProfiles.length" class="muted">
    {{ t("没有匹配的档案") }}
  </p>
  <div v-if="yearly.children.length" class="children-grid">
    <article
      v-for="c in visibleProfiles"
      :key="c.id"
      class="child-profile-card"
      :style="{ '--child-color': c.theme_color }"
    >
      <div class="child-card-top">
        <ChildAvatar class="big-child-avatar" :child="c" /><span class="chip">{{
          c.status === "archived"
            ? t("已归档")
            : c.profile_type === "pet"
              ? t("宠物")
              : t(
                  c.relationship ||
                    (c.profile_type === "child" ? "孩子" : "人物"),
                )
        }}</span>
      </div>
      <h2>
        {{ c.nickname || c.name }}<small v-if="c.nickname">{{ c.name }}</small>
      </h2>
      <p>
        <CalendarDays :size="15" />{{
          c.birthday ? localDate(c.birthday) : t("生日待补充")
        }}<span v-if="c.birth_time">{{ c.birth_time }}</span>
      </p>
      <p
        v-if="c.profile_type === 'pet' && (c.species || c.breed)"
        class="pet-details"
      >
        <PawPrint :size="15" />{{
          [c.species, c.breed].filter(Boolean).join(" · ")
        }}
      </p>
      <p class="child-description">
        {{ c.description || t("每一份陪伴，都值得珍藏。") }}
      </p>
      <div class="child-card-actions">
        <button class="text-button" @click="browse(c.id)">
          {{ t(hasGrowthTimeline(c) ? "翻开成长时间线" : "查看相关影像") }}
          <ArrowUpRight :size="16" /></button
        ><button
          v-if="yearly.canEdit && c.can_edit !== false"
          class="icon-button"
          :aria-label="
            t(c.profile_type === 'pet' ? '编辑宠物档案' : '编辑人物档案')
          "
          @click="edit(c)"
        >
          <Pencil :size="16" />
        </button>
      </div>
    </article>
  </div>
  <EmptyState
    v-else
    :title="t('从一个名字，开始一段故事')"
    :description="
      t('添加人物或宠物，在文件中标记都有谁，共同回忆便能一起找到。')
    "
    ><button v-if="yearly.canEdit" class="button primary" @click="edit()">
      <Plus :size="16" /> {{ t("创建人物档案") }}
    </button></EmptyState
  >
  <ElDialog
    v-model="open"
    :title="
      form.profile_type === 'pet'
        ? t(editing ? '编辑宠物档案' : '添加宠物')
        : t(editing ? '编辑人物档案' : '添加人物')
    "
    width="660px"
    :close-on-click-modal="!busy && !avatarPreparing"
    :close-on-press-escape="!busy && !avatarPreparing"
    :show-close="!busy && !avatarPreparing"
    ><form @submit.prevent="save">
      <div class="avatar-editor">
        <span v-if="avatarPreview" class="child-avatar big-child-avatar"
          ><img :src="avatarPreview" :alt="t('新头像预览')"
        /></span>
        <ChildAvatar v-else class="big-child-avatar" :child="form" />
        <div>
          <input
            ref="avatarInput"
            type="file"
            accept=".jpg,.jpeg,.png,.webp,.heic,.heif"
            hidden
            @change="chooseAvatar"
          />
          <div class="avatar-actions">
            <button
              type="button"
              class="button"
              :disabled="busy || avatarPreparing"
              @click="avatarInput?.click()"
            >
              <Upload :size="16" />{{
                avatarPreparing ? t("正在处理…") : t("上传头像")
              }}
            </button>
            <button
              v-if="avatarPreview || form.avatar_media_id"
              type="button"
              class="text-button"
              :disabled="busy || avatarPreparing"
              @click="
                clearAvatarDraft();
                form.avatar_media_id = null;
              "
            >
              {{ t("清除头像") }}
            </button>
          </div>
          <p class="muted">
            {{
              t("自动居中裁剪，压缩至最长 512 像素。仅用作头像，不加入时间线。")
            }}
          </p>
          <small class="muted">
            {{ t("JPG / PNG / WebP / HEIC，最大 20 MB；保存档案后生效。") }}
          </small>
          <p v-if="avatarProgress !== null" role="status">
            {{ t("头像上传") }} {{ avatarProgress }}%
          </p>
        </div>
      </div>
      <div class="form-row">
        <label>
          {{ t("名字") }}
          <input
            v-model="form.name"
            maxlength="80"
            required
            :placeholder="
              t(form.profile_type === 'pet' ? '宠物的名字' : '人物的名字')
            " /></label
        ><label>
          {{ t("昵称") }}
          <input
            v-model="form.nickname"
            maxlength="80"
            :placeholder="t('家里怎么称呼 TA')"
        /></label>
      </div>
      <label v-if="form.profile_type !== 'pet'">
        {{ t("人物关系（可自定义）") }}
        <input
          v-model="form.relationship"
          list="person-relationships"
          maxlength="80"
          :placeholder="t('例如：爸爸、妈妈、爷爷、奶奶')"
        />
        <datalist id="person-relationships">
          <option v-for="role in personRelationships" :key="role" :value="role">
            {{ t(role) }}
          </option>
        </datalist>
      </label>
      <div v-if="form.profile_type === 'pet'" class="form-row">
        <label
          >{{ t("宠物分类（可自定义）")
          }}<input
            v-model="form.species"
            list="pet-species"
            maxlength="80"
            :placeholder="t('例如：猫、狗、兔子')"
          /><datalist id="pet-species">
            <option
              v-for="species in petSpecies"
              :key="species"
              :value="species"
            >
              {{ t(species) }}
            </option>
          </datalist></label
        >
        <label
          >{{ t("品种（可选）")
          }}<input
            v-model="form.breed"
            maxlength="80"
            :placeholder="t('例如：英短、金毛')"
        /></label>
      </div>
      <label class="checkbox-label">
        <input
          v-model="form.growth_enabled"
          type="checkbox"
          @change="growthTouched = true"
        />{{ t("开启成长时间线") }}
      </label>
      <p class="muted">
        {{
          t(
            "孩子、宠物通常开启；家长等人物可关闭。关闭后仍能标记和筛选影像，不显示年龄与成长节点。",
          )
        }}
      </p>
      <div class="form-row">
        <label>
          {{ t("出生日期（可选）") }}
          <DateField v-model="form.birthday" type="date" /></label
        ><label>
          {{ t("出生时刻（可选）") }}
          <input v-model="form.birth_time" type="time" step="1"
        /></label>
      </div>
      <div class="form-row">
        <label>
          {{ t("性别（可选）") }}
          <select v-model="form.gender">
            <option :value="null">{{ t("暂不填写") }}</option>
            <option :value="t('男')">
              {{ t(form.profile_type === "pet" ? "公" : "男") }}
            </option>
            <option :value="t('女')">
              {{ t(form.profile_type === "pet" ? "母" : "女") }}
            </option>
            <option :value="t('其他')">{{ t("其他") }}</option>
          </select></label
        ><label>
          {{ t("时间线标识颜色") }}
          <input v-model="form.theme_color" type="color"
        /></label>
      </div>
      <label>
        {{ t(form.profile_type === "pet" ? "关于宠物" : "关于人物") }}
        <textarea
          v-model="form.description"
          rows="3"
          :placeholder="t('性格、爱好，或你想对 TA 说的话…')"
        /></label
      ><label>
        {{ t("或从已有照片选择") }}
        <ElSelect
          v-model="form.avatar_media_id"
          filterable
          remote
          clearable
          :remote-method="searchAvatar"
          :disabled="busy || avatarPreparing"
          @change="clearAvatarDraft"
          :placeholder="t('搜索已上传照片标题')"
          @visible-change="(v: boolean) => v && searchAvatar('')"
          ><ElOption
            v-if="
              form.avatar_media_id &&
              !avatarOptions.some((m) => m.id === form.avatar_media_id)
            "
            :value="form.avatar_media_id"
            :label="t('当前头像 #') + form.avatar_media_id" /><ElOption
            v-for="m in avatarOptions"
            :key="m.id"
            :value="m.id"
            :label="m.title || t('照片 #') + m.id" /></ElSelect
      ></label>
      <div class="form-row">
        <label>
          {{ t("显示顺序") }}
          <input type="number" v-model.number="form.sort_order" /></label
        ><label>
          {{ t("档案状态") }}
          <select v-model="form.status">
            <option value="active">{{ t("启用") }}</option>
            <option value="archived">{{ t("归档") }}</option>
          </select></label
        >
      </div>
      <p v-if="form.growth_enabled && !form.birthday" class="muted">
        {{ t("不知道生日也可以记录；补充生日后即可按年龄浏览。") }}
      </p>
      <p v-if="form.growth_enabled" class="muted">
        {{ t("修改生日后，历史影像上的年龄会自动重新计算。") }}
      </p>
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
          {{ t("删除档案") }}</button
        ><button
          type="button"
          class="button"
          :disabled="busy || avatarPreparing"
          @click="open = false"
        >
          {{ t("取消") }}</button
        ><button class="button primary" :disabled="busy || avatarPreparing">
          {{ busy ? t("正在保存…") : t("保存档案") }}
        </button>
      </div>
    </form></ElDialog
  ><ElDialog v-model="deleteOpen" :title="t('确认删除档案')" width="480px"
    ><p>{{ t("删除会解除 TA 与照片、日记的关联。家庭原件会继续保留。") }}</p>
    <label>
      {{ t("再次输入名字「") }} {{ form.name }}」<input v-model="confirmation"
    /></label>
    <div class="dialog-actions">
      <button class="button" @click="deleteOpen = false">{{ t("取消") }}</button
      ><button
        class="button danger-button"
        :disabled="confirmation !== form.name"
        @click="remove"
      >
        {{ t("确认删除档案") }}
      </button>
    </div></ElDialog
  >
</template>

<style scoped>
.profile-list-filters {
  display: flex;
  gap: 12px;
  margin-bottom: 22px;
  flex-wrap: wrap;
}
.profile-list-filters input {
  flex: 1;
  min-width: 180px;
  max-width: 360px;
}

.child-profile-card {
  display: flex;
  flex-direction: column;
}
.child-profile-card .child-description {
  flex: 1;
}
.form-row {
  grid-template-columns: repeat(2, minmax(0, 1fr));
}
.form-row > label {
  min-width: 0;
}

.profile-create-actions {
  display: flex;
  gap: 10px;
  flex-wrap: wrap;
}
.profile-create-actions .button {
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.pet-details {
  color: var(--muted);
}

.avatar-editor {
  display: flex;
  gap: 20px;
  align-items: center;
  margin: 4px 0 24px;
}
.avatar-editor .big-child-avatar {
  flex: 0 0 80px;
  width: 80px;
  height: 80px;
}
.avatar-actions {
  display: flex;
  gap: 16px;
  align-items: center;
}
.avatar-actions .button {
  display: inline-flex;
  align-items: center;
  gap: 8px;
}
.avatar-editor p {
  margin: 10px 0 6px;
  line-height: 1.6;
}
@media (max-width: 600px) {
  .form-row {
    grid-template-columns: 1fr;
    gap: 0;
  }
  .avatar-editor {
    align-items: flex-start;
    gap: 12px;
  }
}
</style>
