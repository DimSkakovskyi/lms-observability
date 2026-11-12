import AdminPanel from "../components/AdminPanel";
import AppHeader from "../components/AppHeader";
import Catalog from "../components/Catalog";
import Hero from "../components/Hero";
import useLmsDashboard from "../hooks/useLmsDashboard";

export default function Dashboard({ token, onLogout }) {
  const dashboard = useLmsDashboard({ token, onLogout });

  function showEditor(course = null) {
    dashboard.openEditor(course);
    window.setTimeout(() => {
      document.getElementById("admin")?.scrollIntoView({
        behavior: "smooth",
        block: "start",
      });
    }, 0);
  }

  function confirmDelete(course) {
    const confirmed = window.confirm(
      `Видалити курс «${course.title}»? Цю дію не можна скасувати.`,
    );
    if (confirmed) dashboard.deleteCourse(course);
  }

  return (
    <div className="app-shell">
      <AppHeader
        user={dashboard.user}
        isAdmin={dashboard.isAdmin}
        onLogout={onLogout}
      />

      <main id="top">
        <Hero
          isAdmin={dashboard.isAdmin}
          publishedCount={dashboard.publishedCount}
          enrollmentCount={dashboard.enrollments.length}
          hiddenCount={dashboard.hiddenCount}
        />

        {(dashboard.error || dashboard.notice) && (
          <div className="status-area" role="status">
            {dashboard.error && <div className="error-banner">{dashboard.error}</div>}
            {dashboard.notice && <div className="success-banner">{dashboard.notice}</div>}
          </div>
        )}

        {dashboard.isAdmin && (
          <AdminPanel
            coursesCount={dashboard.courses.length}
            publishedCount={dashboard.publishedCount}
            hiddenCount={dashboard.hiddenCount}
            editorOpen={dashboard.editorOpen}
            editorCourse={dashboard.editorCourse}
            editorBusy={dashboard.editorBusy}
            onToggleEditor={() => (
              dashboard.editorOpen ? dashboard.closeEditor() : showEditor(null)
            )}
            onCloseEditor={dashboard.closeEditor}
            onSaveCourse={dashboard.saveCourse}
          />
        )}

        <Catalog
          isAdmin={dashboard.isAdmin}
          search={dashboard.search}
          onSearchChange={dashboard.setSearch}
          courses={dashboard.filteredCourses}
          enrollmentByCourse={dashboard.enrollmentByCourse}
          busyId={dashboard.busyId}
          onEnroll={dashboard.enroll}
          onProgress={dashboard.advanceProgress}
          onEdit={showEditor}
          onTogglePublished={dashboard.togglePublished}
          onDelete={confirmDelete}
        />
      </main>

      <footer>
        <span>CourseFlow LMS skeleton</span>
        <span>FastAPI · PostgreSQL · RabbitMQ · Grafana</span>
      </footer>
    </div>
  );
}
