import CourseEditor from "./CourseEditor";

export default function AdminPanel({
  coursesCount,
  publishedCount,
  hiddenCount,
  editorOpen,
  editorCourse,
  editorBusy,
  onToggleEditor,
  onCloseEditor,
  onSaveCourse,
}) {
  return (
    <section className="admin-zone" id="admin">
      <div className="admin-zone-heading">
        <div>
          <p className="eyebrow">Адміністрування</p>
          <h2>Керування каталогом</h2>
          <p>Додавайте курси та змінюйте їхню видимість для студентів.</p>
        </div>
        <button className="admin-primary" type="button" onClick={onToggleEditor}>
          {editorOpen ? "Закрити форму" : "+ Додати курс"}
        </button>
      </div>

      <div className="admin-summary">
        <div><strong>{coursesCount}</strong><span>усього курсів</span></div>
        <div><strong>{publishedCount}</strong><span>бачать студенти</span></div>
        <div><strong>{hiddenCount}</strong><span>приховано</span></div>
      </div>

      {editorOpen && (
        <CourseEditor
          course={editorCourse}
          busy={editorBusy}
          onCancel={onCloseEditor}
          onSave={onSaveCourse}
        />
      )}
    </section>
  );
}
