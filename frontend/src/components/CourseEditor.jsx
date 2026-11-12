import { useEffect, useState } from "react";

export default function CourseEditor({ course, busy, onCancel, onSave }) {
  const editing = Boolean(course?.id);
  const [form, setForm] = useState({
    slug: "",
    title: "",
    description: "",
    instructor: "",
    duration_hours: "",
    published: true,
  });

  useEffect(() => {
    setForm({
      slug: course?.slug || "",
      title: course?.title || "",
      description: course?.description || "",
      instructor: course?.instructor || "",
      duration_hours: course?.duration_hours?.toString() || "",
      published: course?.published ?? true,
    });
  }, [course]);

  function updateField(event) {
    const { name, type, value, checked } = event.target;
    setForm((current) => ({
      ...current,
      [name]: type === "checkbox" ? checked : value,
    }));
  }

  function submit(event) {
    event.preventDefault();
    onSave({
      title: form.title.trim(),
      description: form.description.trim(),
      instructor: form.instructor.trim(),
      duration_hours: Number(form.duration_hours),
      published: form.published,
      ...(!editing ? { slug: form.slug.trim() } : {}),
    });
  }

  return (
    <form className="course-editor" onSubmit={submit}>
      <div className="editor-heading">
        <div>
          <p className="eyebrow">{editing ? "Редагування" : "Новий курс"}</p>
          <h3>{editing ? course.title : "Додати курс до каталогу"}</h3>
        </div>
        {editing && (
          <span className={course.published ? "status-published" : "status-hidden"}>
            {course.published ? "Опубліковано" : "Приховано"}
          </span>
        )}
      </div>

      <div className="editor-grid">
        <label>
          Slug
          <input
            name="slug"
            value={form.slug}
            onChange={updateField}
            placeholder="new-course"
            pattern="[a-z0-9-]+"
            minLength={3}
            maxLength={120}
            disabled={editing}
            required
          />
          <small>{editing ? "Slug не змінюється після створення." : "Латинські літери, цифри та дефіси."}</small>
        </label>

        <label>
          Назва курсу
          <input
            name="title"
            value={form.title}
            onChange={updateField}
            minLength={3}
            maxLength={200}
            required
          />
        </label>

        <label>
          Викладач
          <input
            name="instructor"
            value={form.instructor}
            onChange={updateField}
            minLength={2}
            maxLength={120}
            required
          />
        </label>

        <label>
          Тривалість, годин
          <input
            name="duration_hours"
            value={form.duration_hours}
            onChange={updateField}
            type="number"
            min="0.5"
            max="1000"
            step="0.5"
            required
          />
        </label>

        <label className="editor-description">
          Опис
          <textarea
            name="description"
            value={form.description}
            onChange={updateField}
            minLength={10}
            maxLength={5000}
            rows={4}
            required
          />
        </label>

        <label className="publish-toggle">
          <input
            name="published"
            type="checkbox"
            checked={form.published}
            onChange={updateField}
          />
          <span>
            <strong>Опублікувати курс</strong>
            <small>Опублікований курс одразу бачать студенти.</small>
          </span>
        </label>
      </div>

      <div className="editor-actions">
        <button className="secondary-button" type="button" onClick={onCancel} disabled={busy}>
          Скасувати
        </button>
        <button className="admin-primary" disabled={busy}>
          {busy ? "Збереження…" : editing ? "Зберегти зміни" : "Створити курс"}
        </button>
      </div>
    </form>
  );
}
