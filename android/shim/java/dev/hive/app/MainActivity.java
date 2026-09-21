package dev.hive.app;

import android.app.Activity;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.os.Bundle;
import android.util.Log;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.net.InetAddress;
import java.util.List;
import java.util.Map;

// The whole of a Hive app on Android. The program in lib/arm64-v8a is an
// ordinary Hive executable that already serves its own window over loopback;
// this only starts it, learns the port, and points a WebView at it.
public class MainActivity extends Activity {

	private static final String TAG = "hive";

	// The payload is named lib*.so so the installer extracts it into
	// nativeLibraryDir, which is the one directory in an app that is executable.
	private static final String PAYLOAD = "libhiveapp.so";

	private WebView view;
	private Process child;

	@Override
	protected void onCreate(Bundle state) {
		super.onCreate(state);

		view = new WebView(this);
		WebSettings settings = view.getSettings();
		settings.setJavaScriptEnabled(true);
		settings.setDomStorageEnabled(true);
		// A scene's sounds are part of the program, not something the user asked
		// for a gesture at a time.
		settings.setMediaPlaybackRequiresUserGesture(false);
		view.setWebViewClient(new WebViewClient());

		// API 35 lays an app out edge to edge whether it asked to be. The padding goes
		// on the frame, not the WebView: padding a WebView insets what it draws without
		// changing the size it reports, so 100dvh would still cover the navigation bar.
		FrameLayout frame = new FrameLayout(this);
		frame.addView(view, new FrameLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT,
			ViewGroup.LayoutParams.MATCH_PARENT));
		frame.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
			public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
				v.setPadding(
					insets.getSystemWindowInsetLeft(),
					insets.getSystemWindowInsetTop(),
					insets.getSystemWindowInsetRight(),
					insets.getSystemWindowInsetBottom());
				return insets;
			}
		});

		setContentView(frame);

		Thread runner = new Thread(new Runnable() {
			public void run() {
				serve();
			}
		});
		runner.setDaemon(true);
		runner.start();
	}

	// Starts the program and reads its output until it says where it is
	// listening. Everything it prints goes to logcat either way, which is where
	// a handset's stdout belongs.
	private void serve() {
		try {
			File home = getFilesDir();
			String exe = getApplicationInfo().nativeLibraryDir + "/" + PAYLOAD;

			ProcessBuilder built = new ProcessBuilder(exe);
			built.directory(home);
			built.redirectErrorStream(true);

			Map<String, String> environment = built.environment();
			// hive.env reads .env against the working directory and syslink keeps
			// its cluster key under $HOME, so both are pointed at the app's own
			// storage rather than at "/".
			environment.put("HOME", home.getAbsolutePath());
			environment.put("TMPDIR", getCacheDir().getAbsolutePath());
			String resolvers = resolvers();
			if (!resolvers.isEmpty()) {
				environment.put("HIVE_DNS", resolvers);
			}

			child = built.start();

			BufferedReader out = new BufferedReader(
				new InputStreamReader(child.getInputStream()));
			String line;
			boolean opened = false;
			while ((line = out.readLine()) != null) {
				Log.i(TAG, line);
				if (!opened) {
					String url = addressIn(line);
					if (url != null) {
						opened = true;
						show(url);
					}
				}
			}
			Log.i(TAG, "hive: the program ended");
		} catch (Exception why) {
			Log.e(TAG, "hive: " + why);
		}
	}

	private void show(final String url) {
		runOnUiThread(new Runnable() {
			public void run() {
				view.loadUrl(url);
			}
		});
	}

	// The line the runtime prints when it could not launch a browser of its own,
	// which on a handset is every time. Stage 3 replaces this with a line meant
	// to be read rather than one meant to be helpful.
	private static String addressIn(String line) {
		int at = line.indexOf("http://127.0.0.1:");
		if (at < 0) {
			return null;
		}
		String rest = line.substring(at);
		int space = rest.indexOf(' ');
		if (space >= 0) {
			rest = rest.substring(0, space);
		}
		return rest;
	}

	// Go's pure resolver has no /etc/resolv.conf to read here, so the servers
	// the platform is using are handed over for it to dial directly.
	private String resolvers() {
		StringBuilder said = new StringBuilder();
		try {
			ConnectivityManager manager =
				(ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
			if (manager == null) {
				return "";
			}
			Network active = manager.getActiveNetwork();
			if (active == null) {
				return "";
			}
			LinkProperties properties = manager.getLinkProperties(active);
			if (properties == null) {
				return "";
			}
			List<InetAddress> servers = properties.getDnsServers();
			for (InetAddress server : servers) {
				if (said.length() > 0) {
					said.append(",");
				}
				said.append(server.getHostAddress());
			}
		} catch (Exception why) {
			Log.w(TAG, "hive: no resolvers — " + why);
		}
		return said.toString();
	}

	@Override
	public void onBackPressed() {
		if (view != null && view.canGoBack()) {
			view.goBack();
			return;
		}
		super.onBackPressed();
	}

	// Closing the window ends the program, the same as it does on a desktop.
	@Override
	protected void onDestroy() {
		if (child != null) {
			child.destroy();
			child = null;
		}
		super.onDestroy();
	}
}
