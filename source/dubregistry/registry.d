/**
	Copyright: © 2013 rejectedsoftware e.K.
	License: Subject to the terms of the GNU GPLv3 license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dubregistry.registry;

import dubregistry.cache : FileNotFoundException;
import dubregistry.dbcontroller;
import dubregistry.repositories.repository;

import dub.semver;
import dub.package_ : packageInfoFilenames;
import std.algorithm : canFind, countUntil, filter, map, sort, swap;
import std.array;
import std.datetime : Clock, UTC, hours, SysTime;
import std.encoding : sanitize;
import std.exception : enforce;
import std.range : chain, walkLength;
import std.string : format, startsWith, toLower;
import std.typecons;
import userman.db.controller;
import vibe.core.core;
import vibe.core.log;
import vibe.data.bson;
import vibe.data.json;
import vibe.stream.operations;
import vibe.utils.array : FixedRingBuffer;


/// Settings to configure the package registry.
class DubRegistrySettings {
	string databaseName = "vpmreg";
}

class DubRegistry {
	private {
		DubRegistrySettings m_settings;
		DbController m_db;
		Json[string] m_packageInfos;

		// list of package names to check for updates
		FixedRingBuffer!string m_updateQueue;
		string m_currentUpdatePackage;
		Task m_updateQueueTask;
		TaskMutex m_updateQueueMutex;
		TaskCondition m_updateQueueCondition;
		SysTime m_lastSignOfLifeOfUpdateTask;
	}

	this(DubRegistrySettings settings)
	{
		m_settings = settings;
		m_db = new DbController(settings.databaseName);
		m_updateQueue.capacity = 10000;
		m_updateQueueMutex = new TaskMutex;
		m_updateQueueCondition = new TaskCondition(m_updateQueueMutex);
		m_updateQueueTask = runTask(&processUpdateQueue);
	}

	@property DbController db() nothrow { return m_db; }

	@property auto availablePackages() { return m_db.getAllPackages(); }
	@property auto availablePackageIDs() { return m_db.getAllPackageIDs(); }

	auto getPackageDump()
	{
		return m_db.getPackageDump();
	}

	void triggerPackageUpdate(string pack_name)
	{
		synchronized (m_updateQueueMutex) {
			if (!m_updateQueue[].canFind(pack_name))
				m_updateQueue.put(pack_name);
		}

		// watchdog for update task
		if (Clock.currTime(UTC()) - m_lastSignOfLifeOfUpdateTask > 2.hours) {
			logError("Update task has hung. Trying to interrupt.");
			m_updateQueueTask.interrupt();
		}

		if (!m_updateQueueTask.running)
			m_updateQueueTask = runTask(&processUpdateQueue);
		m_updateQueueCondition.notifyAll();
	}

	bool isPackageScheduledForUpdate(string pack_name)
	{
		if (m_currentUpdatePackage == pack_name) return true;
		synchronized (m_updateQueueMutex)
			if (m_updateQueue[].canFind(pack_name)) return true;
		return false;
	}

	/** Returns the current index of a given package in the update queue.

		An index of zero indicates that the package is currently being updated.
		A negative index is returned when the package is not in the update
		queue.
	*/
	sizediff_t getUpdateQueuePosition(string pack_name)
	{
		if (m_currentUpdatePackage == pack_name) return 0;
		synchronized (m_updateQueueMutex) {
			auto idx = m_updateQueue[].countUntil(pack_name);
			return idx >= 0 ? idx + 1 : -1;
		}
	}

	auto searchPackages(string query)
	{
		static struct Info { string name; DbPackageVersion _base; alias _base this; }
		return m_db.searchPackages(query).filter!(p => p.versions.length > 0).map!(p =>
			Info(p.name, m_db.getVersionInfo(p.name, p.versions[$ - 1].version_)));
	}

	RepositoryInfo getRepositoryInfo(Json repository)
	{
		auto rep = getRepository(repository);
		return rep.getInfo();
	}

	void addPackage(Json repository, User.ID user)
	{
		auto pack_name = validateRepository(repository);

		DbPackage pack;
		pack.owner = user.bsonObjectIDValue;
		pack.name = pack_name;
		pack.repository = repository;
		m_db.addPackage(pack);

		triggerPackageUpdate(pack.name);
	}

	void addOrSetPackage(DbPackage pack)
	{
		m_db.addOrSetPackage(pack);
		if (auto pi = pack.name in m_packageInfos)
			m_packageInfos.remove(pack.name);
	}

	void addDownload(BsonObjectID pack_id, string ver, string agent)
	{
		m_db.addDownload(pack_id, ver, agent);
	}

	void removePackage(string packname, User.ID user)
	{
		logInfo("Removing package %s of %s", packname, user);
		m_db.removePackage(packname, user.bsonObjectIDValue);
		if (packname in m_packageInfos) m_packageInfos.remove(packname);
	}

	auto getPackages(User.ID user)
	{
		return m_db.getUserPackages(user.bsonObjectIDValue);
	}

	bool isUserPackage(User.ID user, string package_name)
	{
		return m_db.isUserPackage(user.bsonObjectIDValue, package_name);
	}

	Json getPackageStats(string packname)
	{
		DbPackage pack;
		try pack = m_db.getPackage(packname);
		catch(Exception) return Json(null);
		return PackageStats(m_db.getDownloadStats(pack._id)).serializeToJson();
	}

	Json getPackageStats(string packname, string ver)
	{
		DbPackage pack;
		try pack = m_db.getPackage(packname);
		catch(Exception) return Json(null);
		if (ver == "latest") ver = getLatestVersion(packname);
		if (!m_db.hasVersion(packname, ver)) return Json(null);
		return PackageStats(m_db.getDownloadStats(pack._id, ver)).serializeToJson();
	}

	Json getPackageVersionInfo(string packname, string ver)
	{
		if (ver == "latest") ver = getLatestVersion(packname);
		if (!m_db.hasVersion(packname, ver)) return Json(null);
		return m_db.getVersionInfo(packname, ver).serializeToJson();
	}

	string getLatestVersion(string packname)
	{
		return m_db.getLatestVersion(packname);
	}

	Json getPackageInfo(string packname, bool include_errors = false)
	{
		if (!include_errors) {
			if (auto ppi = packname in m_packageInfos)
				return *ppi;
		}

		DbPackage pack;
		try pack = m_db.getPackage(packname);
		catch(Exception) return Json(null);

		auto ret = getPackageInfo(pack, include_errors);
		if (!include_errors)
			m_packageInfos[packname] = ret;
		return ret;
	}

	Json getPackageInfo(DbPackage pack, bool include_errors)
	{
		auto rep = getRepository(pack.repository);

		Json[] vers;
		foreach (v; pack.versions) {
			auto nfo = v.info;
			nfo["version"] = v.version_;
			nfo["date"] = v.date.toISOExtString();
			nfo["url"] = rep.getDownloadUrl(v.version_.startsWith("~") ? v.version_ : "v"~v.version_); // obsolete, will be removed in april 2013
			if (v.readme.length && v.readme.length < 256 && v.readme[0] == '/') {
				try {
					rep.readFile(v.commitID, Path(v.readme), (scope data) { nfo["readme"] = data.readAllUTF8(); });
				} catch (Exception e) {
					logDebug("Failed to read README file (%s) for %s %s", v.readme, pack.name, v.version_);
				}
			}
			vers ~= nfo;
		}

		Json ret = Json.emptyObject;
		ret["id"] = pack._id.toString();
		ret["dateAdded"] = pack._id.timeStamp.toISOExtString();
		ret["owner"] = pack.owner.toString();
		ret["name"] = pack.name;
		ret["versions"] = Json(vers);
		ret["repository"] = pack.repository;
		ret["categories"] = serializeToJson(pack.categories);
		if(include_errors) ret["errors"] = serializeToJson(pack.errors);
		return ret;
	}

	void downloadPackageZip(string packname, string vers, void delegate(scope InputStream) del)
	{
		DbPackage pack = m_db.getPackage(packname);
		auto rep = getRepository(pack.repository);
		rep.download(vers, del);
	}

	void setPackageCategories(string pack_name, string[] categories)
	{
		m_db.setPackageCategories(pack_name, categories);
		if (pack_name in m_packageInfos) m_packageInfos.remove(pack_name);
	}

	void setPackageRepository(string pack_name, Json repository)
	{
		auto new_name = validateRepository(repository);
		enforce(pack_name == new_name, "The package name of the new repository doesn't match the existing one: "~new_name);
		m_db.setPackageRepository(pack_name, repository);
		if (pack_name in m_packageInfos) m_packageInfos.remove(pack_name);
	}

	void checkForNewVersions()
	{
		logInfo("Triggering check for new versions...");
		foreach (packname; this.availablePackages)
			triggerPackageUpdate(packname);
	}

	protected string validateRepository(Json repository)
	{
		// find the packge info of ~master or any available branch
		PackageVersionInfo info;
		auto rep = getRepository(repository);
		auto branches = rep.getBranches();
		enforce(branches.length > 0, "The repository contains no branches.");
		auto idx = branches.countUntil!(b => b.name == "master");
		if (idx > 0) swap(branches[0], branches[idx]);
		string branch_errors;
		foreach (b; branches) {
			try {
				info = rep.getVersionInfo(b, null);
				enforce (info.info.type == Json.Type.object,
					"JSON package description must be a JSON object.");
				break;
			} catch (Exception e) {
				logDiagnostic("Error getting package info for %s", b);
				branch_errors ~= format("\n%s: %s", b.name, e.msg);
			}
		}
		enforce (info.info.type == Json.Type.object,
			"Failed to find a branch containing a valid package description file:" ~ branch_errors);

		// derive package name and perform various sanity checks
		auto name = info.info["name"].get!string;
		string package_desc_file = info.info["packageDescriptionFile"].get!string;
		string package_check_string = format(`Check your %s.`, package_desc_file);
		enforce(name.length <= 60,
			"Package names must not be longer than 60 characters: \""~name[0 .. 60]~"...\" - "~package_check_string);
		enforce(name == name.toLower(),
			"Package names must be all lower case, not \""~name~"\". "~package_check_string);
		enforce(info.info["license"].opt!string.length > 0,
			`A "license" field in the package description file is missing or empty. `~package_check_string);
		enforce(info.info["description"].opt!string.length > 0,
			`A "description" field in the package description file is missing or empty. `~package_check_string);
		checkPackageName(name, format(`Check the "name" field of your %s.`, package_desc_file));
		foreach (string n, vspec; info.info["dependencies"].opt!(Json[string])) {
			auto parts = n.split(":").array;
			// allow shortcut syntax ":subpack"
			if (parts.length > 1 && parts[0].length == 0) parts = parts[1 .. $];
			// verify all other parts of the package name
			foreach (p; parts)
				checkPackageName(p, format(`Check the "dependencies" field of your %s.`, package_desc_file));
		}

		// ensure that at least one tagged version is present
		auto tags = rep.getTags();
		enforce(tags.canFind!(t => t.name.startsWith("v") && t.name[1 .. $].isValidVersion),
			`The repository must have at least one tagged version (SemVer format, e.g. `
			~ `"v1.0.0" or "v0.0.1") to be published on the registry. Please add a proper tag using `
			~ `"git tag" or equivalent means and see http://semver.org for more information.`);

		return name;
	}

	protected bool addVersion(string packname, string ver, Repository rep, RefInfo reference)
	{
		logDiagnostic("Adding new version info %s for %s", ver, packname);
		assert(ver.startsWith("~") && !ver.startsWith("~~") || isValidVersion(ver));

		auto dbpack = m_db.getPackage(packname);
		string deffile;
		foreach (t; dbpack.versions)
			if (t.version_ == ver) {
				deffile = t.info["packageDescriptionFile"].opt!string;
				break;
			}
		auto info = getVersionInfo(rep, reference, deffile);

		// clear cached Json
		if (packname in m_packageInfos) m_packageInfos.remove(packname);

		//assert(info.info.name == info.info.name.get!string.toLower(), "Package names must be all lower case.");
		info.info["name"] = info.info["name"].get!string.toLower();
		enforce(info.info["name"] == packname,
			format("Package name (%s) does not match the original package name (%s). Check %s.",
				info.info["name"].get!string, packname, info.info["packageDescriptionFile"].get!string));

		if ("description" !in info.info || "license" !in info.info) {
		//enforce("description" in info.info && "license" in info.info,
			throw new Exception(
			"Published packages must contain \"description\" and \"license\" fields.");
		}

		foreach( string n, vspec; info.info["dependencies"].opt!(Json[string]) )
			foreach (p; n.split(":"))
				checkPackageName(p, "Check "~info.info["packageDescriptionFile"].get!string~".");

		DbPackageVersion dbver;
		dbver.date = info.date;
		dbver.version_ = ver;
		dbver.commitID = info.sha;
		dbver.info = info.info;

		try {
			rep.readFile(reference.sha, Path("/README.md"), (scope input) { input.readAll(); });
			dbver.readme = "/README.md";
		} catch (Exception e) { logDiagnostic("No README.md found for %s %s", packname, ver); }

		if (m_db.hasVersion(packname, ver)) {
			logDebug("Updating existing version info.");
			m_db.updateVersion(packname, dbver);
			return false;
		}

		//enforce(!m_db.hasVersion(packname, dbver.version_), "Version already exists.");
		if (auto pv = "version" in info.info)
			enforce(pv.get!string == ver, format("Package description contains an obsolete \"version\" field and does not match tag %s: %s", ver, pv.get!string));
		logDebug("Adding new version info.");
		m_db.addVersion(packname, dbver);
		return true;
	}

	protected void removeVersion(string packname, string ver)
	{
		assert(ver.startsWith("~") && !ver.startsWith("~~") || isValidVersion(ver));

		// clear cached Json
		if (packname in m_packageInfos) m_packageInfos.remove(packname);

		m_db.removeVersion(packname, ver);
	}

	private void processUpdateQueue()
	{
		scope (exit) logWarn("Update task was killed!");
		while (true) {
			m_lastSignOfLifeOfUpdateTask = Clock.currTime(UTC());
			logDiagnostic("Getting new package to be updated...");
			string pack;
			synchronized (m_updateQueueMutex) {
				while (m_updateQueue.empty) {
					logDiagnostic("Waiting for package to be updated...");
					m_updateQueueCondition.wait();
				}
				pack = m_updateQueue.front;
				m_updateQueue.popFront();
				m_currentUpdatePackage = pack;
			}
			scope(exit) m_currentUpdatePackage = null;
			logDiagnostic("Updating package %s.", pack);
			try checkForNewVersions(pack);
			catch (Exception e) {
				logWarn("Failed to check versions for %s: %s", pack, e.msg);
				logDiagnostic("Full error: %s", e.toString().sanitize);
			}
		}
	}

	private void checkForNewVersions(string packname)
	{
		import std.encoding;
		string[] errors;

		Json pack;
		try pack = getPackageInfo(packname);
		catch( Exception e ){
			errors ~= format("Error getting package info: %s", e.msg);
			logDebug("%s", sanitize(e.toString()));
			return;
		}

		Repository rep;
		try rep = getRepository(pack["repository"]);
		catch( Exception e ){
			errors ~= format("Error accessing repository: %s", e.msg);
			logDebug("%s", sanitize(e.toString()));
			return;
		}

		bool[string] existing;
		RefInfo[] tags, branches;
		bool got_all_tags_and_branches = false;
		try {
			tags = rep.getTags()
				.filter!(a => a.name.startsWith("v") && a.name[1 .. $].isValidVersion)
				.array
				.sort!((a, b) => compareVersions(a.name[1 .. $], b.name[1 .. $]) < 0)
				.array;
			branches = rep.getBranches();
			got_all_tags_and_branches = true;
		} catch (Exception e) {
			errors ~= format("Failed to get GIT tags/branches: %s", e.msg);
		}
		logInfo("Updating tags for %s: %s", packname, tags.map!(t => t.name).array);
		foreach (tag; tags) {
			auto name = tag.name[1 .. $];
			existing[name] = true;
			try {
				if (addVersion(packname, name, rep, tag))
					logInfo("Added version %s of %s", name, packname);
			} catch( Exception e ){
				logInfo("Error for version %s of %s: %s", name, packname, e.msg);
				logDebug("Full error: %s", sanitize(e.toString()));
				errors ~= format("Version %s: %s", name, e.msg);
			}
		}
		logInfo("Updating branches for %s: %s", packname, branches.map!(t => t.name).array);
		foreach (branch; branches) {
			auto name = "~" ~ branch.name;
			existing[name] = true;
			try {
				if (addVersion(packname, name, rep, branch))
					logInfo("Added branch %s for %s", name, packname);
			} catch( Exception e ){
				logInfo("Error for branch %s of %s: %s", name, packname, e.msg);
				logDebug("Full error: %s", sanitize(e.toString()));
				if (branch.name != "gh-pages") // ignore errors on the special GitHub website branch
					errors ~= format("Branch %s: %s", name, e.msg);
			}
		}
		if (got_all_tags_and_branches) {
			foreach (v; pack["versions"]) {
				auto ver = v["version"].get!string;
				if (ver !in existing) {
					logInfo("Removing version %s as the branch/tag was removed.", ver);
					removeVersion(packname, ver);
				}
			}
		}
		m_db.setPackageErrors(packname, errors);
	}
}

private PackageVersionInfo getVersionInfo(Repository rep, RefInfo commit, string first_filename_try)
{
	import dub.recipe.io;
	import dub.recipe.json;

	PackageVersionInfo ret;
	ret.date = commit.date.toSysTime();
	ret.sha = commit.sha;
	foreach (filename; chain((&first_filename_try)[0 .. 1], packageInfoFilenames.filter!(f => f != first_filename_try))) {
		if (!filename.length) continue;
		try {
			rep.readFile(commit.sha, Path("/" ~ filename), (scope input) {
				auto text = input.readAllUTF8(false);
				auto recipe = parsePackageRecipe(text, filename);
				ret.info = recipe.toJson();
			});

			ret.info["packageDescriptionFile"] = filename;
			logDebug("Found package description file %s.", filename);
			break;
		} catch (FileNotFoundException) {
			logDebug("Package description file %s not found...", filename);
		}
	}
	if (ret.info.type == Json.Type.undefined)
		 throw new Exception("Found no package description file in the repository.");
	return ret;
}

private void checkPackageName(string n, string error_suffix)
{
	enforce(n.length > 0, "Package names may not be empty. "~error_suffix);
	foreach( ch; n ){
		switch(ch){
			default:
				throw new Exception("Package names may only contain ASCII letters and numbers, as well as '_' and '-': "~n~" - "~error_suffix);
			case 'a': .. case 'z':
			case 'A': .. case 'Z':
			case '0': .. case '9':
			case '_', '-':
				break;
		}
	}
}

struct PackageStats {
	DbDownloadStats downloads;
}

private struct PackageVersionInfo {
	SysTime date;
	string sha;
	Json info;
}
