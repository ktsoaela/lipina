from django.urls import path

from . import views

urlpatterns = [
    path("register/", views.RegisterView.as_view(), name="register"),
    path("token/", views.LoginView.as_view(), name="token"),
    path("token/refresh/", views.RefreshView.as_view(), name="token-refresh"),
    path("me/", views.MeView.as_view(), name="me"),
    path("password/", views.ChangePasswordView.as_view(), name="change-password"),
]
